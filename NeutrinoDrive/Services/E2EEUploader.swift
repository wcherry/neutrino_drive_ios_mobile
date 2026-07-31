import Foundation
import Sodium
import os.log

// MARK: - UploadError

enum UploadError: LocalizedError {
    case noEncryptionKey
    case encryptionFailed
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)
    case fileReadError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noEncryptionKey:          return "No encryption key found. Please import a key before uploading."
        case .encryptionFailed:         return "Failed to encrypt the file."
        case .notAuthenticated:         return "You are not signed in."
        case .networkError:             return "A network error occurred. Please check your connection."
        case .serverError(let code):    return "Server error (\(code))."
        case .decodingError(let err):   return "Failed to read server response: \(err.localizedDescription)"
        case .fileReadError(let err):   return "Failed to read file: \(err.localizedDescription)"
        }
    }
}

// MARK: - UploadResult

struct UploadResult {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
}

// MARK: - E2EEUploader

/// The end-to-end-encrypted upload protocol, extracted from `UploadService` so the share
/// extension can run **the same code** rather than a reimplementation that could drift.
///
/// This type is deliberately plain: no `@MainActor`, no `ObservableObject`, no reference to
/// `DriveService` or anything in `Views/`. That is what keeps the set of source files shared
/// with the extension target small — see "Code-sharing strategy" in
/// `agent_docs/plans/feature-phase2-biometrics-share-background.md`.
///
/// `UploadService` retains its published `isUploading`/`progress`/`error` state and simply
/// delegates the cryptography and the network round trip here, so `UploadSheet`'s behaviour is
/// unchanged.
struct E2EEUploader {

    // MARK: - Dependencies

    let transferService: BackgroundTransferService

    init(transferService: BackgroundTransferService = .shared) {
        self.transferService = transferService
    }

    // MARK: - Private

    private static let sodium = Sodium()

    private var logger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive", category: "E2EEUploader")
    }

    private static let decoder: JSONDecoder = {
        let make = { (format: String) -> DateFormatter in
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            return f
        }
        let formatters = [
            make("yyyy-MM-dd'T'HH:mm:ss.SSSSSS"),
            make("yyyy-MM-dd'T'HH:mm:ss"),
        ]
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                            category: "E2EEUploader")
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            for formatter in formatters {
                if let date = formatter.date(from: raw) { return date }
            }
            logger.error("date decode failed: \(raw, privacy: .public)")
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Cannot parse date: \(raw)"
            ))
        }
        return d
    }()

    private var baseURL: String { SharedStorage.serverHost }

    // MARK: - Upload

    /// Encrypt `data` locally, upload the ciphertext, and store the sealed DEK.
    /// Mirrors the web's `uploadEncryptedFile` flow exactly.
    ///
    /// - Parameter progress: called with 0…1 as the request body is sent. Invoked on the
    ///   transfer session's delegate queue, **not** the main queue — callers that publish to
    ///   SwiftUI must hop themselves.
    func upload(data: Data,
                fileName: String,
                mimeType plainMimeType: String,
                parentFolderID: String?,
                progress: ((Double) -> Void)? = nil) async throws -> UploadResult {

        logger.debug("upload: \(data.count) bytes name=\(fileName, privacy: .public) folder=\(parentFolderID ?? "root", privacy: .public)")

        guard SharedStorage.hasStoredKeys() else {
            throw UploadError.noEncryptionKey
        }
        guard let token = SharedStorage.accessToken() else {
            throw UploadError.notAuthenticated
        }

        let plainData = data

        // MARK: Step 2 — Generate DEK and encrypt file (XChaCha20-Poly1305 secretstream)
        //
        // Output format matches the web's encryptFile():
        //   [24-byte header][ciphertext]

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let dek: Bytes = xcss.key()

        guard let filePushStream = xcss.initPush(secretKey: dek) else {
            throw UploadError.encryptionFailed
        }
        let fileHeader = filePushStream.header()
        guard let fileCiphertext = filePushStream.push(message: Array(plainData), tag: .FINAL) else {
            throw UploadError.encryptionFailed
        }
        let encryptedData = Data(fileHeader + fileCiphertext)

        logger.debug("upload: encrypted \(plainData.count) → \(encryptedData.count) bytes")

        // MARK: Step 3 — Encrypt metadata { name, mimeType } with DEK
        //
        // Matches the web's encryptMetadata({ name, mimeType }, dek).
        // Stored on the server so the plaintext MIME type can be recovered after decryption.

        let metadataDict: [String: String] = ["name": fileName, "mimeType": plainMimeType]
        guard let metadataJSON = try? JSONSerialization.data(withJSONObject: metadataDict,
                                                             options: [.sortedKeys]) else {
            throw UploadError.encryptionFailed
        }
        guard let metaPushStream = xcss.initPush(secretKey: dek) else {
            throw UploadError.encryptionFailed
        }
        let metaHeader = metaPushStream.header()
        guard let metaCiphertext = metaPushStream.push(message: Array(metadataJSON), tag: .FINAL) else {
            throw UploadError.encryptionFailed
        }
        guard let encryptedMetadata = Self.sodium.utils.bin2base64(
            metaHeader + metaCiphertext, variant: .URLSAFE_NO_PADDING
        ) else {
            throw UploadError.encryptionFailed
        }

        // MARK: Step 4 — Seal DEK to user's Curve25519 public key (crypto_box_seal)
        //
        // Matches the web's encryptFileKey(dek, kp.publicKey).

        // Sealing runs through `SealedKeyCrypto` — the same primitive `SharingService` uses to
        // re-wrap this DEK to a recipient. Sharing a file must produce a key wrapped exactly
        // the way upload wraps it, and sharing one implementation is what guarantees that.
        guard let pubKeyString = KeychainService.load(forKey: SharedStorage.Keys.publicKey) else {
            throw UploadError.noEncryptionKey
        }
        guard let encryptedFileKey = SealedKeyCrypto.seal(dek: dek,
                                                          toPublicKeyBase64URL: pubKeyString) else {
            throw UploadError.encryptionFailed
        }

        // MARK: Step 5 — POST multipart (folder_id?, encrypted_metadata, file blob)
        //
        // The body is written to a temp file rather than held as `Data`, because a background
        // URLSession only accepts `uploadTask(with:fromFile:)` — `Data` and stream bodies are
        // rejected outright. `BackgroundTransferService` owns deleting the file once the task
        // completes, since it must outlive this function's return.

        guard let uploadURL = URL(string: baseURL + "/api/v1/drive/files/upload") else {
            throw UploadError.serverError(statusCode: 0)
        }
        let boundary = UUID().uuidString
        let body = Self.buildMultipartBody(
            encryptedData: encryptedData,
            fileName: fileName,
            mimeType: plainMimeType,
            parentFolderID: parentFolderID,
            encryptedMetadata: encryptedMetadata,
            boundary: boundary
        )

        let bodyFileURL: URL
        do {
            bodyFileURL = try Self.writeTemporaryBody(body)
        } catch {
            throw UploadError.fileReadError(underlying: error)
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("multipart/form-data; boundary=\(boundary)",
                               forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        logger.debug("--> POST \(uploadURL.path, privacy: .public) (\(body.count) bytes)")

        let uploadData: Data
        let http: HTTPURLResponse
        do {
            (uploadData, http) = try await transferService.upload(
                request: uploadRequest,
                fromFile: bodyFileURL,
                progress: progress
            )
        } catch {
            logger.error("upload network error: \(error, privacy: .public)")
            throw UploadError.networkError(underlying: error)
        }

        logger.debug("<-- \(http.statusCode) \(uploadURL.path, privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            throw UploadError.serverError(statusCode: http.statusCode)
        }

        let apiResponse: APIUploadResponse
        do {
            apiResponse = try Self.decoder.decode(APIUploadResponse.self, from: uploadData)
        } catch {
            throw UploadError.decodingError(underlying: error)
        }

        // MARK: Step 6 — Store sealed DEK on server
        //
        // Matches the web's PUT /api/v1/drive/files/{id}/key after uploadEncryptedFile.

        try await storeFileKey(fileID: apiResponse.id, encryptedFileKey: encryptedFileKey, token: token)

        let result = UploadResult(
            id:        apiResponse.id,
            name:      apiResponse.name,
            folderId:  apiResponse.folderId,
            sizeBytes: apiResponse.sizeBytes,
            mimeType:  apiResponse.mimeType,
            updatedAt: apiResponse.updatedAt
        )
        logger.debug("upload succeeded: id=\(result.id, privacy: .public) name=\(result.name, privacy: .public)")
        return result
    }

    // MARK: - Private Helpers

    private func storeFileKey(fileID: String, encryptedFileKey: String, token: String) async throws {
        guard let url = URL(string: baseURL + "/api/v1/drive/files/\(fileID)/key") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(["encryptedFileKey": encryptedFileKey])

        logger.debug("--> PUT /api/v1/drive/files/\(fileID, privacy: .public)/key")

        // Deliberately on the foreground session: background sessions do not support data
        // tasks, and this payload is a few hundred bytes.
        let keyResponse: URLResponse
        do {
            (_, keyResponse) = try await transferService.data(for: req)
        } catch {
            logger.error("storeFileKey network error: \(error, privacy: .public)")
            throw UploadError.networkError(underlying: error)
        }
        if let http = keyResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            logger.error("storeFileKey server error: \(http.statusCode)")
            throw UploadError.serverError(statusCode: http.statusCode)
        }
        logger.debug("<-- key stored for \(fileID, privacy: .public)")
    }

    /// Writes the multipart body to a UUID-named file directly in the temp directory.
    ///
    /// Flat rather than inside a per-upload subdirectory: the UUID already guarantees two
    /// concurrent uploads cannot collide, and a bare file means `BackgroundTransferService`'s
    /// `removeItem` is *complete* cleanup. With a subdirectory it would delete the file and
    /// leave the empty directory behind, leaking one per upload.
    private static func writeTemporaryBody(_ body: Data) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nd-upload-\(UUID().uuidString).multipart")
        try body.write(to: fileURL, options: .atomic)
        return fileURL
    }

    static func buildMultipartBody(
        encryptedData: Data,
        fileName: String,
        mimeType: String,
        parentFolderID: String?,
        encryptedMetadata: String,
        boundary: String
    ) -> Data {
        var body = Data()
        let dash = "--"
        let crlf = "\r\n"

        func append(_ string: String) {
            if let d = string.data(using: .utf8) { body.append(d) }
        }

        // encrypted_metadata (required — contains { name, mimeType } encrypted with DEK)
        append("\(dash)\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"encrypted_metadata\"\(crlf)")
        append(crlf)
        append(encryptedMetadata)
        append(crlf)

        // folder_id (optional)
        if let folderID = parentFolderID {
            append("\(dash)\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"folder_id\"\(crlf)")
            append(crlf)
            append(folderID)
            append(crlf)
        }

        // encrypted file blob — Content-Type carries plaintext MIME type so the server stores
        // it in the DB directly; the same value is also inside encrypted_metadata for E2EE clients.
        append("\(dash)\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(crlf)")
        append("Content-Type: \(mimeType)\(crlf)")
        append(crlf)
        body.append(encryptedData)
        append(crlf)

        append("\(dash)\(boundary)\(dash)\(crlf)")
        return body
    }
}

// MARK: - API Response

private struct APIUploadResponse: Decodable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
}

// MARK: - Data + Base64URL

extension Data {
    /// Shared by `E2EEUploader` and `DownloadService`. Declared internal (rather than the
    /// duplicated `private` copies that existed before) so the extension target compiles a
    /// single definition.
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let r = s.count % 4
        if r != 0 { s += String(repeating: "=", count: 4 - r) }
        self.init(base64Encoded: s)
    }
}
