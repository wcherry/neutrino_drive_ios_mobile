import Foundation
import Sodium
import UniformTypeIdentifiers
import os.log

// MARK: - DownloadError

enum DownloadError: LocalizedError {
    case noEncryptionKey
    case decryptionFailed
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)
    case fileWriteError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noEncryptionKey:          return "No encryption key found. Please import a key before downloading."
        case .decryptionFailed:         return "Failed to decrypt the file."
        case .notAuthenticated:         return "You are not signed in."
        case .networkError:             return "A network error occurred. Please check your connection."
        case .serverError(let code):    return "Server error (\(code))."
        case .decodingError(let err):   return "Failed to read server response: \(err.localizedDescription)"
        case .fileWriteError(let err):  return "Failed to save file: \(err.localizedDescription)"
        }
    }
}

// MARK: - DownloadService

@MainActor
final class DownloadService: ObservableObject {

    // MARK: - Published State

    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0   // 0.0 to 1.0
    @Published var error: String?

    // MARK: - Private

    private static let sodium = Sodium()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "DownloadService")

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    // MARK: - Download

    /// Download and decrypt a Drive file. Returns a URL to the plaintext temp file.
    /// Mirrors the web's downloadAndDecryptFile flow exactly.
    func download(fileID: String, fileName: String, mimeType: String?) async throws -> URL {
        logger.debug("download: fileID=\(fileID, privacy: .public) name=\(fileName, privacy: .public)")

        guard KeyImportService.hasStoredKeys() else {
            throw DownloadError.noEncryptionKey
        }

        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw DownloadError.notAuthenticated
        }

        isDownloading = true
        progress = 0
        error = nil
        defer { isDownloading = false }

        // MARK: Step 1 — Fetch sealed DEK from server
        //
        // Mirrors the web's GET /api/v1/drive/files/{id}/key.

        let encryptedFileKey = try await fetchSealedDEK(fileID: fileID, token: token)
        progress = 0.2

        // MARK: Step 2 — Unseal DEK with private key (crypto_box_seal_open)
        //
        // Mirrors the web's decryptFileKey(encryptedFileKey, kp.privateKey).

        guard let pubKeyString = KeychainService.load(forKey: KeyImportService.publicKeyKeychainKey),
              let pubKeyData = Data(base64URLEncoded: pubKeyString),
              let privKeyString = KeychainService.load(forKey: KeyImportService.privateKeyKeychainKey),
              let privKeyData = Data(base64URLEncoded: privKeyString) else {
            throw DownloadError.noEncryptionKey
        }

        guard let sealedDEKBytes = Self.sodium.utils.base642bin(
            encryptedFileKey, variant: .URLSAFE_NO_PADDING
        ) else {
            throw DownloadError.decryptionFailed
        }

        guard let dek: Bytes = Self.sodium.box.open(
            anonymousCipherText: sealedDEKBytes,
            recipientPublicKey: Array(pubKeyData),
            recipientSecretKey: Array(privKeyData)
        ) else {
            logger.error("download: failed to unseal DEK for \(fileID, privacy: .public)")
            throw DownloadError.decryptionFailed
        }

        progress = 0.4

        // MARK: Step 3 — Download encrypted file blob

        let encryptedData = try await fetchEncryptedFile(fileID: fileID, token: token)
        logger.debug("download: received \(encryptedData.count) bytes")
        progress = 0.7

        // MARK: Step 4 — Decrypt file (XChaCha20-Poly1305 secretstream)
        //
        // Input format: [24-byte header][ciphertext]
        // Mirrors the web's decryptFile(encryptedBuffer, dek).

        let headerSize = 24
        guard encryptedData.count > headerSize else {
            throw DownloadError.decryptionFailed
        }
        let header = Array(encryptedData.prefix(headerSize))
        let ciphertext = Array(encryptedData.dropFirst(headerSize))

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        guard let pullStream = xcss.initPull(secretKey: dek, header: header) else {
            throw DownloadError.decryptionFailed
        }
        guard let (plaintext, _) = pullStream.pull(cipherText: ciphertext) else {
            logger.error("download: XChaCha20-Poly1305 pull failed for \(fileID, privacy: .public)")
            throw DownloadError.decryptionFailed
        }

        progress = 0.9

        // MARK: Step 5 — Write plaintext to a UUID-named temp directory
        //
        // Placing the file in its own directory keeps the original fileName so
        // QuickLook and share sheets display the correct name.

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appendingPathComponent(fileName)
            try Data(plaintext).write(to: tempURL)
            progress = 1
            logger.debug("download succeeded: \(fileName, privacy: .public) → \(tempURL.path, privacy: .public)")
            return tempURL
        } catch {
            throw DownloadError.fileWriteError(underlying: error)
        }
    }

    // MARK: - Private Helpers

    private func fetchSealedDEK(fileID: String, token: String) async throws -> String {
        guard let url = URL(string: baseURL + "/api/v1/drive/files/\(fileID)/key") else {
            throw DownloadError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        logger.debug("--> GET /api/v1/drive/files/\(fileID, privacy: .public)/key")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            logger.error("fetchSealedDEK network error: \(error, privacy: .public)")
            throw DownloadError.networkError(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) /api/v1/drive/files/\(fileID, privacy: .public)/key")
        guard (200...299).contains(http.statusCode) else {
            throw DownloadError.serverError(statusCode: http.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let body = try decoder.decode(APIKeyResponse.self, from: data)
            return body.encryptedFileKey
        } catch {
            throw DownloadError.decodingError(underlying: error)
        }
    }

    private func fetchEncryptedFile(fileID: String, token: String) async throws -> Data {
        guard let url = URL(string: baseURL + "/api/v1/drive/files/\(fileID)") else {
            throw DownloadError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        logger.debug("--> GET /api/v1/drive/files/\(fileID, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            logger.error("fetchEncryptedFile network error: \(error, privacy: .public)")
            throw DownloadError.networkError(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) /api/v1/drive/files/\(fileID, privacy: .public) (\(data.count) bytes)")
        guard (200...299).contains(http.statusCode) else {
            throw DownloadError.serverError(statusCode: http.statusCode)
        }

        return data
    }
}

// MARK: - API Response

private struct APIKeyResponse: Decodable {
    let encryptedFileKey: String
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
