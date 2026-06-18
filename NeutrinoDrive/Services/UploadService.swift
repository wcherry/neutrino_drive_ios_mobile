import Foundation
import Sodium
import UniformTypeIdentifiers
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

// MARK: - UploadService

@MainActor
final class UploadService: ObservableObject {

    // MARK: - Published State

    @Published var isUploading: Bool = false
    @Published var progress: Double = 0   // 0.0 to 1.0
    @Published var error: String?

    // MARK: - Dependencies

    weak var driveService: DriveService?

    // MARK: - Private

    private static let sodium = Sodium()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "UploadService")

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
                            category: "UploadService")
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

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    // MARK: - Upload

    /// Encrypt `fileURL` locally, upload the ciphertext, and store the sealed DEK.
    /// Mirrors the web's `uploadEncryptedFile` flow exactly.
    func upload(fileURL: URL, parentFolderID: String?) async throws -> UploadResult {
        logger.debug("upload: file=\(fileURL.lastPathComponent, privacy: .public) folder=\(parentFolderID ?? "root", privacy: .public)")

        guard KeyImportService.hasStoredKeys() else {
            throw UploadError.noEncryptionKey
        }

        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw UploadError.notAuthenticated
        }

        isUploading = true
        progress = 0
        error = nil
        defer { isUploading = false }

        // MARK: Step 1 — Read plaintext file

        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { fileURL.stopAccessingSecurityScopedResource() } }

        let plainData: Data
        do {
            plainData = try Data(contentsOf: fileURL)
        } catch {
            throw UploadError.fileReadError(underlying: error)
        }

        let fileName = fileURL.lastPathComponent
        let plainMimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                          ?? "application/octet-stream"

        logger.debug("upload: \(plainData.count) bytes mimeType=\(plainMimeType, privacy: .public)")

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

        guard let pubKeyString = KeychainService.load(forKey: KeyImportService.publicKeyKeychainKey),
              let pubKeyData = Data(base64URLEncoded: pubKeyString) else {
            throw UploadError.noEncryptionKey
        }
        guard let sealedDEK = Self.sodium.box.seal(message: dek,
                                                   recipientPublicKey: Array(pubKeyData)) else {
            throw UploadError.encryptionFailed
        }
        guard let encryptedFileKey = Self.sodium.utils.bin2base64(sealedDEK, variant: .URLSAFE_NO_PADDING) else {
            throw UploadError.encryptionFailed
        }

        // MARK: Step 5 — POST multipart (folder_id?, encrypted_metadata, file blob)

        guard let uploadURL = URL(string: baseURL + "/api/v1/drive/files/upload") else {
            throw UploadError.serverError(statusCode: 0)
        }
        let boundary = UUID().uuidString
        let body = buildMultipartBody(
            encryptedData: encryptedData,
            fileName: fileName,
            mimeType: plainMimeType,
            parentFolderID: parentFolderID,
            encryptedMetadata: encryptedMetadata,
            boundary: boundary
        )

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("multipart/form-data; boundary=\(boundary)",
                               forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        logger.debug("--> POST \(uploadURL.path, privacy: .public) (\(body.count) bytes)")

        let uploadData: Data
        let uploadResponse: URLResponse
        do {
            (uploadData, uploadResponse) = try await URLSession.shared.upload(
                for: uploadRequest, from: body
            )
        } catch {
            logger.error("upload network error: \(error, privacy: .public)")
            throw UploadError.networkError(underlying: error)
        }

        guard let http = uploadResponse as? HTTPURLResponse else {
            throw UploadError.serverError(statusCode: 0)
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

        // MARK: Step 7 — Optimistic UI update

        let result = UploadResult(
            id:        apiResponse.id,
            name:      apiResponse.name,
            folderId:  apiResponse.folderId,
            sizeBytes: apiResponse.sizeBytes,
            mimeType:  apiResponse.mimeType,
            updatedAt: apiResponse.updatedAt
        )
        driveService?.fileWasUploaded(result)
        progress = 1
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

        let (_, keyResponse): (Data, URLResponse)
        do {
            (_, keyResponse) = try await URLSession.shared.data(for: req)
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

    private func buildMultipartBody(
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

private extension Data {
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let r = s.count % 4
        if r != 0 { s += String(repeating: "=", count: 4 - r) }
        self.init(base64Encoded: s)
    }
}
