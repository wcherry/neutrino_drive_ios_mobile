import Foundation
import Sodium
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
    /// The ciphertext is larger than the caller is willing to hold in memory at once.
    ///
    /// Only the File Provider extension raises this today. See
    /// `FileProviderLimits.maxMaterializableBytes` for why refusing is better than trying.
    case tooLargeToDecrypt(sizeBytes: Int64, limitBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .noEncryptionKey:          return "No encryption key found. Please import a key before downloading."
        case .decryptionFailed:         return "Failed to decrypt the file."
        case .notAuthenticated:         return "You are not signed in."
        case .networkError:             return "A network error occurred. Please check your connection."
        case .serverError(let code):    return "Server error (\(code))."
        case .decodingError(let err):   return "Failed to read server response: \(err.localizedDescription)"
        case .fileWriteError(let err):  return "Failed to save file: \(err.localizedDescription)"
        case .tooLargeToDecrypt(let size, let limit):
            let f = ByteCountFormatter()
            return "This file is too large to open here (\(f.string(fromByteCount: size)); "
                 + "the limit is \(f.string(fromByteCount: limit))). Open it in the Neutrino Drive app instead."
        }
    }
}

// MARK: - E2EEDownloader

/// The end-to-end-encrypted download protocol — fetch the sealed DEK, unseal it, fetch the
/// ciphertext blob, decrypt it, write the plaintext out.
///
/// **Why this type exists.** It is the exact counterpart of the Phase 2 `E2EEUploader`
/// extraction, and for the same reason: the File Provider extension must materialize files by
/// running *the same decrypt the app runs*, not a reimplementation of it. A divergence here
/// would not fail a build and would not fail a request — it would hand the Files app plausible
/// garbage. Compiling literally this file into both targets is what rules that out. See
/// "Code-sharing strategy" in `agent_docs/plans/feature-phase2-biometrics-share-background.md`.
///
/// Deliberately plain: no `@MainActor`, no `ObservableObject`, no `AuthService`, nothing from
/// `Views/`. `DownloadService` keeps its published `isDownloading`/`progress`/`error` surface
/// and delegates here, so every existing call site is unchanged.
///
/// ## The memory shape, which is the whole constraint
///
/// Decryption is whole-file and in-memory: libsodium's secretstream is opened over one
/// `[24-byte header][ciphertext]` buffer and pulled in a single call. Peak usage is therefore
/// roughly *two* copies of the file. In the app that is merely wasteful. In an extension with a
/// small memory budget it is a jetsam kill, which the Files app reports as an uninformative
/// generic failure. `maxDecryptBytes` exists so a caller can refuse clearly instead.
///
/// Streaming decryption would fix this for both, and is a tracked follow-up rather than
/// something this branch attempts.
struct E2EEDownloader {

    // MARK: - Dependencies

    let transferService: BackgroundTransferService

    /// Refuse to decrypt ciphertext larger than this. `nil` means no limit — the app's
    /// behaviour, preserved exactly as it was before this extraction.
    let maxDecryptBytes: Int64?

    init(transferService: BackgroundTransferService = .shared,
         maxDecryptBytes: Int64? = nil) {
        self.transferService = transferService
        self.maxDecryptBytes = maxDecryptBytes
    }

    // MARK: - Private

    private static let sodium = Sodium()

    private var logger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive", category: "E2EEDownloader")
    }

    private var baseURL: String { SharedStorage.serverHost }

    // MARK: - Paths

    /// The blob path for a file, or for one of its historical versions.
    ///
    /// Kept as a pure static function — as it was on `DownloadService` — because the full
    /// download flow cannot be exercised in the test harness (it first requires an encryption
    /// keypair in the Keychain, which the test host does not persist), and path construction is
    /// the part of version downloading that could silently be wrong.
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

    // MARK: - Download

    /// Download and decrypt a Drive file. Returns a URL to the plaintext temp file.
    ///
    /// - Parameter versionID: when non-nil, fetches that historical version's blob instead of
    ///   the current file. Everything else — the key fetch, the unseal, the secretstream
    ///   decrypt — is identical, which is why it is a parameter and not a second method.
    /// - Parameter progress: called with 0…1. Invoked on the transfer session's delegate
    ///   queue, **not** the main queue — callers that publish to SwiftUI must hop themselves.
    func download(fileID: String,
                  fileName: String,
                  versionID: String? = nil,
                  progress: ((Double) -> Void)? = nil) async throws -> URL {

        logger.debug("download: fileID=\(fileID, privacy: .public) version=\(versionID ?? "current", privacy: .public)")

        guard SharedStorage.hasStoredKeys() else {
            throw DownloadError.noEncryptionKey
        }
        guard let token = SharedStorage.accessToken() else {
            throw DownloadError.notAuthenticated
        }

        // MARK: Step 1 — Fetch the sealed DEK
        let encryptedFileKey = try await fetchSealedDEK(fileID: fileID, token: token)
        progress?(0.2)

        // MARK: Step 2 — Unseal the DEK (crypto_box_seal_open)
        guard SealedKeyCrypto.storedKeyPair() != nil else {
            throw DownloadError.noEncryptionKey
        }
        guard let dek: Bytes = SealedKeyCrypto.openDEKWithStoredKeys(
            sealedBase64URL: encryptedFileKey
        ) else {
            logger.error("download: failed to unseal DEK for \(fileID, privacy: .public)")
            throw DownloadError.decryptionFailed
        }
        progress?(0.4)

        // MARK: Step 3 — Fetch the ciphertext blob
        let encryptedData = try await fetchEncryptedFile(fileID: fileID,
                                                         versionID: versionID,
                                                         token: token,
                                                         progress: progress)
        logger.debug("download: received \(encryptedData.count) bytes")
        progress?(0.7)

        // MARK: Step 4 — Decrypt (XChaCha20-Poly1305 secretstream)
        //
        // Input format: [24-byte header][ciphertext]. Mirrors the web's decryptFile.
        let plaintext = try decrypt(encryptedData, with: dek, fileID: fileID)
        progress?(0.9)

        // MARK: Step 5 — Write the plaintext to a UUID-named temp directory
        //
        // Its own directory so the original fileName is preserved, which is what QuickLook,
        // share sheets, and the Files app display.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appendingPathComponent(fileName)
            try Data(plaintext).write(to: tempURL)
            progress?(1)
            logger.debug("download succeeded: \(fileName, privacy: .public)")
            return tempURL
        } catch {
            throw DownloadError.fileWriteError(underlying: error)
        }
    }

    // MARK: - Decrypt

    private func decrypt(_ encryptedData: Data, with dek: Bytes, fileID: String) throws -> Bytes {
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
        return plaintext
    }

    // MARK: - Network

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
            return try decoder.decode(SealedKeyResponse.self, from: data).encryptedFileKey
        } catch {
            throw DownloadError.decodingError(underlying: error)
        }
    }

    /// Fetches the ciphertext via `BackgroundTransferService.download`, so a large file keeps
    /// transferring if iOS suspends the app mid-download. The delivered file is read into memory
    /// for decryption and then removed.
    ///
    /// The size ceiling is enforced **after** the transfer and **before** the read, which is the
    /// only point where the real ciphertext size is known: the caller's advertised size can be
    /// stale or absent, and reading first would be the allocation the ceiling exists to prevent.
    private func fetchEncryptedFile(fileID: String,
                                    versionID: String?,
                                    token: String,
                                    progress: ((Double) -> Void)?) async throws -> Data {
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
                progress: { fraction in
                    // Step 3 spans the 0.4…0.7 band of the overall progress bar.
                    progress?(0.4 + (fraction * 0.3))
                }
            )
        } catch {
            logger.error("fetchEncryptedFile network error: \(error, privacy: .public)")
            throw DownloadError.networkError(underlying: error)
        }

        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        logger.debug("<-- \(http.statusCode) \(path, privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            throw DownloadError.serverError(statusCode: http.statusCode)
        }

        if let limit = maxDecryptBytes,
           let actual = Self.fileSizeBytes(at: fileURL), actual > limit {
            logger.error("fetchEncryptedFile: \(actual) bytes exceeds limit \(limit)")
            throw DownloadError.tooLargeToDecrypt(sizeBytes: actual, limitBytes: limit)
        }

        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw DownloadError.fileWriteError(underlying: error)
        }
    }

    static func fileSizeBytes(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        if let size = attrs[.size] as? Int64 { return size }
        if let size = attrs[.size] as? UInt64 { return Int64(size) }
        if let size = attrs[.size] as? NSNumber { return size.int64Value }
        return nil
    }
}

// MARK: - API Response

private struct SealedKeyResponse: Decodable {
    let encryptedFileKey: String
}
