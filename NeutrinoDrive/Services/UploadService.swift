import Foundation
import CryptoKit
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
        case .noEncryptionKey:              return "No encryption key found. Please import a key before uploading."
        case .encryptionFailed:             return "Failed to encrypt the file."
        case .notAuthenticated:             return "You are not signed in."
        case .networkError:                 return "A network error occurred. Please check your connection."
        case .serverError(let code):        return "Server error (\(code))."
        case .decodingError(let err):       return "Failed to read server response: \(err.localizedDescription)"
        case .fileReadError(let err):       return "Failed to read file: \(err.localizedDescription)"
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

    /// Set at app launch so the service can optimistically update the file list after upload.
    weak var driveService: DriveService?

    // MARK: - Shared Decoder

    private static let decoder: JSONDecoder = {
        let make = { (format: String) -> DateFormatter in
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            return f
        }
        let formatters = [
            make("yyyy-MM-dd'T'HH:mm:ss.SSSSSS"),   // with microseconds
            make("yyyy-MM-dd'T'HH:mm:ss"),           // without fractional seconds
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
            logger.error("date decode failed: unexpected value=\(raw, privacy: .public) at \(decoder.codingPath.map(\.stringValue).joined(separator: "."), privacy: .public)")
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Cannot parse date: \(raw)"
            ))
        }
        return d
    }()

    // MARK: - Logging

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "UploadService")

    // MARK: - Configuration

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    // MARK: - Upload

    /// Upload a file at the given local URL into `parentFolderID` (nil = root).
    /// Returns the server-assigned UploadResult on success.
    func upload(fileURL: URL, parentFolderID: String?) async throws -> UploadResult {
        logger.debug("upload: file=\(fileURL.lastPathComponent, privacy: .public) parentFolderID=\(parentFolderID ?? "root", privacy: .public)")

        // Verify encryption keys exist before doing any IO work.
        guard KeyImportService.hasStoredKeys() else {
            logger.error("upload: no encryption key in keychain")
            throw UploadError.noEncryptionKey
        }

        isUploading = true
        progress = 0
        error = nil

        defer {
            isUploading = false
        }

        // MARK: Step 1 — Read file data

        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { fileURL.stopAccessingSecurityScopedResource() }
        }

        let plainData: Data
        do {
            plainData = try Data(contentsOf: fileURL)
        } catch {
            logger.error("upload: file read failed: \(error, privacy: .public)")
            throw UploadError.fileReadError(underlying: error)
        }

        let originalSize = plainData.count
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                     ?? "application/octet-stream"
        let fileName  = fileURL.lastPathComponent

        logger.debug("upload: read \(originalSize) bytes mimeType=\(mimeType, privacy: .public)")

        // MARK: Step 2 — Hybrid encryption

        let symmetricKey = SymmetricKey(size: .bits256)
        let encryptedData: Data
        do {
            let sealedBox = try AES.GCM.seal(plainData, using: symmetricKey)
            guard let combined = sealedBox.combined else {
                throw UploadError.encryptionFailed
            }
            encryptedData = combined
        } catch let uploadErr as UploadError {
            throw uploadErr
        } catch {
            logger.error("upload: encryption failed: \(error, privacy: .public)")
            throw UploadError.encryptionFailed
        }

        logger.debug("upload: encrypted \(originalSize) bytes → \(encryptedData.count) bytes")

        // MARK: Step 3 — Build multipart request

        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            logger.error("upload: no access token in keychain — user must re-login")
            throw UploadError.notAuthenticated
        }

        guard let url = URL(string: baseURL + "/api/v1/drive/files/upload") else {
            throw UploadError.serverError(statusCode: 0)
        }

        let boundary = UUID().uuidString
        let body = buildMultipartBody(
            encryptedData: encryptedData,
            fileName: fileName,
            mimeType: mimeType,
            parentFolderID: parentFolderID,
            originalSize: originalSize,
            boundary: boundary
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // MARK: Step 4 — Perform upload

        logger.debug("--> POST \(url.path, privacy: .public) (\(body.count) bytes multipart)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            logger.error("network error: \(url.path, privacy: .public) \(error, privacy: .public)")
            throw UploadError.networkError(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UploadError.serverError(statusCode: 0)
        }

        logger.debug("<-- \(http.statusCode) \(url.path, privacy: .public)")

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("server error \(http.statusCode) \(url.path, privacy: .public): \(body, privacy: .public)")
            throw UploadError.serverError(statusCode: http.statusCode)
        }

        // MARK: Step 5 — Decode response

        let apiResponse: APIUploadResponse
        do {
            apiResponse = try Self.decoder.decode(APIUploadResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("decode error \(url.path, privacy: .public): \(error, privacy: .public) body=\(body, privacy: .public)")
            throw UploadError.decodingError(underlying: error)
        }

        let result = UploadResult(
            id:        apiResponse.id,
            name:      apiResponse.name,
            folderId:  apiResponse.folderId,
            sizeBytes: apiResponse.sizeBytes,
            mimeType:  apiResponse.mimeType,
            updatedAt: apiResponse.updatedAt
        )

        logger.debug("upload succeeded: id=\(result.id, privacy: .public) name=\(result.name, privacy: .public)")

        // MARK: Step 6 — Optimistic update

        driveService?.fileWasUploaded(result)
        progress = 1

        return result
    }

    // MARK: - Private Helpers

    private func buildMultipartBody(
        encryptedData: Data,
        fileName: String,
        mimeType: String,
        parentFolderID: String?,
        originalSize: Int,
        boundary: String
    ) -> Data {
        var body = Data()

        let dash = "--"
        let crlf = "\r\n"

        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        // File field (encrypted blob sent as binary)
        append("\(dash)\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(crlf)")
        append("Content-Type: application/octet-stream\(crlf)")
        append(crlf)
        body.append(encryptedData)
        append(crlf)

        // Text fields
        let textFields: [(name: String, value: String)] = [
            ("name",       fileName),
            ("mime_type",  mimeType),
            ("size_bytes", String(originalSize)),
        ]

        for field in textFields {
            append("\(dash)\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"\(field.name)\"\(crlf)")
            append(crlf)
            append(field.value)
            append(crlf)
        }

        // Optional folder_id field
        if let folderID = parentFolderID {
            append("\(dash)\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"folder_id\"\(crlf)")
            append(crlf)
            append(folderID)
            append(crlf)
        }

        // Closing boundary
        append("\(dash)\(boundary)\(dash)\(crlf)")

        return body
    }
}

// MARK: - API Response Model

private struct APIUploadResponse: Decodable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
}
