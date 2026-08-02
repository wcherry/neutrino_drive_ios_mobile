import Foundation
import UniformTypeIdentifiers
import os.log

// MARK: - DownloadService

/// The app-facing download surface: published `isDownloading`/`progress`/`error` for SwiftUI,
/// wrapping the actual E2EE pipeline in `E2EEDownloader`.
///
/// The pipeline moved out in Phase 3 so the File Provider extension can run the *same* decrypt
/// rather than a reimplementation of it — the identical reasoning that produced `E2EEUploader`
/// in Phase 2. This type's public surface, its error type, and its behaviour are unchanged;
/// `DownloadError` now lives in `E2EEDownloader.swift`, which is a file move, not a rename.
@MainActor
final class DownloadService: ObservableObject {

    // MARK: - Published State

    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0   // 0.0 to 1.0
    @Published var error: String?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "DownloadService")

    private let downloader: E2EEDownloader

    // MARK: - Init

    /// - Parameter session: injectable so tests can stub network responses with
    ///   `MockURLProtocol`; when omitted the shared background-session transfer service is used.
    init(session: URLSession? = nil) {
        if let session {
            self.downloader = E2EEDownloader(transferService: BackgroundTransferService(session: session))
        } else {
            self.downloader = E2EEDownloader(transferService: .shared)
        }
    }

    // MARK: - Download

    /// Download and decrypt a Drive file. Returns a URL to the plaintext temp file.
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

        // Checked here as well as inside `E2EEDownloader` so the published `isDownloading`
        // spinner is never raised for a request that cannot start.
        guard KeyImportService.hasStoredKeys() else {
            throw DownloadError.noEncryptionKey
        }
        guard KeychainService.load(forKey: AuthService.accessTokenKey) != nil else {
            throw DownloadError.notAuthenticated
        }

        isDownloading = true
        progress = 0
        error = nil
        defer { isDownloading = false }

        return try await downloader.download(
            fileID: fileID,
            fileName: fileName,
            versionID: versionID,
            progress: { [weak self] fraction in
                // `E2EEDownloader` reports progress on the transfer session's delegate queue.
                Task { @MainActor in self?.progress = fraction }
            }
        )
    }

    // MARK: - Path helpers
    //
    // Retained on this type because `DownloadServiceTests` asserts against them; both forward
    // to `E2EEDownloader`, which is the single definition.

    static func blobPath(fileID: String, versionID: String?) -> String {
        E2EEDownloader.blobPath(fileID: fileID, versionID: versionID)
    }

    static func blobTransferID(fileID: String, versionID: String?) -> String {
        E2EEDownloader.blobTransferID(fileID: fileID, versionID: versionID)
    }
}
