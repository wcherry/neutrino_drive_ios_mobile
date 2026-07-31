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

    private var baseURL: String { SharedStorage.serverHost }

    /// The encrypted blob is fetched through this so the transfer survives app suspension.
    /// The small sealed-key JSON call goes through its foreground session — background
    /// sessions do not support data tasks.
    private let transferService: BackgroundTransferService

    // MARK: - Init

    /// - Parameter session: injectable so tests can stub network responses with
    ///   `MockURLProtocol`; when omitted the shared background-session transfer service is used.
    init(session: URLSession? = nil) {
        if let session {
            self.transferService = BackgroundTransferService(session: session)
        } else {
            self.transferService = .shared
        }
    }

    // MARK: - Download

    /// Download and decrypt a Drive file. Returns a URL to the plaintext temp file.
    /// Mirrors the web's downloadAndDecryptFile flow exactly.
    ///
    /// - Parameter versionID: when non-nil, fetches that historical version's blob from
    ///   `/files/{id}/versions/{vid}/download` instead of the current file. Everything else —
    ///   the key fetch, the unseal, the secretstream decrypt — is **identical**, which is the
    ///   whole reason this is a parameter rather than a second method.
    ///
    ///   Historical versions are decryptable with the file's *current* DEK because the server
    ///   stores no per-version key (`FileVersionResponse` has no key field; a version snapshot
    ///   is a byte copy of the blob) and clients reuse a file's DEK across saves. See
    ///   "Version history and the DEK question" in
    ///   `agent_docs/plans/feature-phase5-sharing-versions-favorites.md`.
    func download(fileID: String,
                  fileName: String,
                  mimeType: String?,
                  versionID: String? = nil) async throws -> URL {
        logger.debug("download: fileID=\(fileID, privacy: .public) name=\(fileName, privacy: .public) version=\(versionID ?? "current", privacy: .public)")

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

        // Unsealing runs through `SealedKeyCrypto`, the same primitive `SharingService` uses to
        // read a DEK before re-wrapping it for a recipient.
        guard SealedKeyCrypto.storedKeyPair() != nil else {
            throw DownloadError.noEncryptionKey
        }
        guard let dek: Bytes = SealedKeyCrypto.openDEKWithStoredKeys(
            sealedBase64URL: encryptedFileKey
        ) else {
            logger.error("download: failed to unseal DEK for \(fileID, privacy: .public)")
            throw DownloadError.decryptionFailed
        }

        progress = 0.4

        // MARK: Step 3 — Download encrypted file blob (background session)

        let encryptedData = try await fetchEncryptedFile(fileID: fileID,
                                                         versionID: versionID,
                                                         token: token)
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
            (data, response) = try await transferService.data(for: req)
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

    /// Fetches the ciphertext blob via `BackgroundTransferService.download`, so a large file
    /// keeps transferring if iOS suspends the app mid-download. The delivered file is read into
    /// memory for decryption and then removed — streaming decryption is a separate follow-up
    /// (see the memory note in `feature-photo-auto-sync.md`).
    /// The blob path for a file, or for one of its historical versions.
    ///
    /// Extracted as a pure function purely so it can be unit-tested: the full download flow
    /// cannot be exercised in this test harness, because it first requires an encryption
    /// keypair in the Keychain and the test host's Keychain does not persist one (the same
    /// limitation behind the pre-existing `test_download_throwsNotAuthenticated_…` failure).
    /// Path construction is the part of version downloading that could silently be wrong, so
    /// it is the part made testable.
    static func blobPath(fileID: String, versionID: String?) -> String {
        guard let versionID else { return "/api/v1/drive/files/\(fileID)" }
        return "/api/v1/drive/files/\(fileID)/versions/\(versionID)/download"
    }

    /// Transfer identifier for a blob fetch. Distinct per version so a version download and a
    /// current-file download of the same file are never mistaken for one another by the
    /// background session's orphan-claim path.
    static func blobTransferID(fileID: String, versionID: String?) -> String {
        guard let versionID else { return "download-\(fileID)" }
        return "download-\(fileID)-v\(versionID)"
    }

    private func fetchEncryptedFile(fileID: String,
                                    versionID: String?,
                                    token: String) async throws -> Data {
        let path = Self.blobPath(fileID: fileID, versionID: versionID)
        guard let url = URL(string: baseURL + path) else {
            throw DownloadError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        logger.debug("--> GET \(path, privacy: .public)")

        let fileURL: URL
        let http: HTTPURLResponse
        do {
            (fileURL, http) = try await transferService.download(
                request: req,
                transferID: Self.blobTransferID(fileID: fileID, versionID: versionID),
                progress: { [weak self] fraction in
                    Task { @MainActor in
                        // Step 3 spans the 0.4…0.7 band of the overall progress bar.
                        self?.progress = 0.4 + (fraction * 0.3)
                    }
                }
            )
        } catch {
            logger.error("fetchEncryptedFile network error: \(error, privacy: .public)")
            throw DownloadError.networkError(underlying: error)
        }

        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        logger.debug("<-- \(http.statusCode) /api/v1/drive/files/\(fileID, privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            throw DownloadError.serverError(statusCode: http.statusCode)
        }

        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw DownloadError.fileWriteError(underlying: error)
        }
    }
}

// MARK: - API Response

private struct APIKeyResponse: Decodable {
    let encryptedFileKey: String
}
