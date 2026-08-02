import Foundation
// Only for the `Bytes` typealias on the unsealed DEK. The secretstream pull that used to live
// here now runs in `SecretStreamCrypto` against the raw C API, because the Swift wrapper only
// offers the one-shot whole-message form.
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
    /// The ciphertext is larger than the caller is willing to process at all.
    ///
    /// Only the File Provider extension raises this today. See
    /// `FileProviderLimits.maxMaterializableBytes` — note that since the decrypt became
    /// constant-memory this is a prudence guard, no longer a memory ceiling.
    case tooLargeToDecrypt(sizeBytes: Int64, limitBytes: Int64)
    /// The Poly1305 tag did not verify: the ciphertext was corrupted or tampered with.
    ///
    /// Deliberately distinct from `decryptionFailed`. "We could not decrypt this" and "the
    /// bytes the server sent are not the bytes that were uploaded" are different events, and
    /// collapsing the second into the first would hide the only signal a client gets that its
    /// storage provider returned something it should not have.
    case integrityCheckFailed

    var errorDescription: String? {
        switch self {
        case .noEncryptionKey:          return "No encryption key found. Please import a key before downloading."
        case .decryptionFailed:         return "Failed to decrypt the file."
        case .notAuthenticated:         return "You are not signed in."
        case .networkError:             return "A network error occurred. Please check your connection."
        case .serverError(let code):    return "Server error (\(code))."
        case .decodingError(let err):   return "Failed to read server response: \(err.localizedDescription)"
        case .fileWriteError(let err):  return "Failed to save file: \(err.localizedDescription)"
        case .integrityCheckFailed:
            return "This file failed its integrity check. It may be corrupted, or it may have "
                 + "been altered since it was uploaded. It has not been saved."
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
/// ## The memory shape — fixed, and how
///
/// This used to be the whole constraint. Decryption was whole-file and in-memory: libsodium's
/// secretstream was opened over one `[24-byte header][ciphertext]` buffer and pulled in a
/// single call, so peak usage was roughly *two* copies of the file. In the app that was merely
/// wasteful; in an extension with a small memory budget it was a jetsam kill, which the Files
/// app reports as an uninformative generic failure. That is why materialization was capped at
/// 64 MB.
///
/// It is now streamed. `SecretStreamCrypto.decrypt(fileAt:to:key:)` reads the ciphertext from
/// disk in 1 MiB chunks and writes plaintext straight out, verifying the Poly1305 MAC over the
/// whole message before the result is allowed to exist. **Peak memory is the chunk size, not
/// the file size** — a 4 GB file costs what a 4 MB one costs. Neither the ciphertext nor the
/// plaintext is ever fully resident.
///
/// The decrypt fails closed: on a MAC mismatch the partial output is deleted and
/// `integrityCheckFailed` is thrown, so no caller can be handed unverified plaintext.
///
/// `maxDecryptBytes` survives as a *prudence* guard rather than a memory ceiling — see
/// `FileProviderLimits`.
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

        // MARK: Step 3 — Fetch the ciphertext blob to disk
        //
        // The delivered file is deliberately *not* read into memory. It is handed to the
        // streaming decrypt as a file URL, which is what keeps peak usage flat.
        let cipherURL = try await fetchEncryptedFile(fileID: fileID,
                                                     versionID: versionID,
                                                     token: token,
                                                     progress: progress)
        defer { try? FileManager.default.removeItem(at: cipherURL.deletingLastPathComponent()) }
        progress?(0.7)

        // MARK: Step 4/5 — Stream-decrypt straight into a UUID-named temp directory
        //
        // Its own directory so the original fileName is preserved, which is what QuickLook,
        // share sheets, and the Files app display.
        //
        // Decrypt and write are one step now rather than two: plaintext goes from the chunk
        // buffer to the destination file without ever existing as a whole `Data`.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tempURL = tempDir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.fileWriteError(underlying: error)
        }

        do {
            try SecretStreamCrypto.decrypt(
                fileAt: cipherURL,
                to: tempURL,
                key: dek,
                progress: { fraction in progress?(0.7 + (fraction * 0.3)) }
            )
        } catch let error as SecretStreamError {
            try? FileManager.default.removeItem(at: tempDir)
            switch error {
            case .authenticationFailed:
                logger.error("download: INTEGRITY FAILURE for \(fileID, privacy: .public)")
                throw DownloadError.integrityCheckFailed
            case .ioError:
                throw DownloadError.fileWriteError(underlying: error)
            default:
                logger.error("download: decrypt failed for \(fileID, privacy: .public): \(error, privacy: .public)")
                throw DownloadError.decryptionFailed
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw DownloadError.fileWriteError(underlying: error)
        }

        progress?(1)
        logger.debug("download succeeded: \(fileName, privacy: .public)")
        return tempURL
    }

    // MARK: - Network

    /// Fetch the file's DEK and unseal it with the stored keypair.
    ///
    /// Exposed (rather than left inline in `download`) so `StreamingPlaybackService` obtains a
    /// DEK through **this** path instead of a second copy of the fetch-and-unseal sequence.
    /// The same reasoning that produced `SealedKeyCrypto`: a divergent key path fails no build
    /// and no request, it just decrypts to garbage.
    func unsealedDEK(fileID: String) async throws -> [UInt8] {
        guard SharedStorage.hasStoredKeys() else { throw DownloadError.noEncryptionKey }
        guard let token = SharedStorage.accessToken() else { throw DownloadError.notAuthenticated }
        let sealed = try await fetchSealedDEK(fileID: fileID, token: token)
        guard let dek = SealedKeyCrypto.openDEKWithStoredKeys(sealedBase64URL: sealed) else {
            throw DownloadError.decryptionFailed
        }
        return dek
    }

    func fetchSealedDEK(fileID: String, token: String) async throws -> String {
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
    /// transferring if iOS suspends the app mid-download.
    ///
    /// **Returns a file URL, not `Data`.** It used to return `Data`, and that single
    /// `Data(contentsOf:)` was half of the whole-file memory problem. The caller streams the
    /// returned file through `SecretStreamCrypto` and owns deleting its enclosing directory.
    ///
    /// The size ceiling is enforced **after** the transfer, which is the only point where the
    /// real ciphertext size is known: the caller's advertised size can be stale or absent.
    private func fetchEncryptedFile(fileID: String,
                                    versionID: String?,
                                    token: String,
                                    progress: ((Double) -> Void)?) async throws -> URL {
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

        logger.debug("<-- \(http.statusCode) \(path, privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            throw DownloadError.serverError(statusCode: http.statusCode)
        }

        if let limit = maxDecryptBytes,
           let actual = Self.fileSizeBytes(at: fileURL), actual > limit {
            logger.error("fetchEncryptedFile: \(actual) bytes exceeds limit \(limit)")
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            throw DownloadError.tooLargeToDecrypt(sizeBytes: actual, limitBytes: limit)
        }

        return fileURL
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
