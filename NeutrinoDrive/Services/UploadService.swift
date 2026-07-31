import Foundation
import UniformTypeIdentifiers
import os.log

// `UploadError` and `UploadResult` now live in `E2EEUploader.swift` alongside the protocol
// implementation itself, so the share extension can compile them without pulling in this
// `@MainActor` `ObservableObject`.

// MARK: - UploadService

/// UI-facing wrapper around ``E2EEUploader``.
///
/// Owns the `isUploading` / `progress` / `error` state that `UploadSheet` binds to, and
/// notifies `DriveService` of completed uploads. All cryptography and networking is delegated
/// to `E2EEUploader`, which since the background-transfers change routes the blob POST through
/// ``BackgroundTransferService`` — so a transfer in flight when iOS suspends the app now
/// survives instead of dying and restarting from zero.
///
/// `PhotoSyncService` uploads through this same method, which is how photo auto-sync inherits
/// background transfers without any change of its own.
@MainActor
final class UploadService: ObservableObject {

    // MARK: - Published State

    @Published var isUploading: Bool = false
    @Published var progress: Double = 0   // 0.0 to 1.0
    @Published var error: String?

    // MARK: - Dependencies

    weak var driveService: DriveService?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "UploadService")

    private let uploader: E2EEUploader

    // MARK: - Init

    /// - Parameter session: injectable so tests can stub network responses with
    ///   `MockURLProtocol`. When supplied, transfers run on that session in foreground mode;
    ///   `URLProtocol` subclasses are never consulted by a background session, so this is the
    ///   only way the pipeline can be exercised in-process.
    ///   When omitted, the shared background-session transfer service is used.
    init(session: URLSession? = nil) {
        if let session {
            self.uploader = E2EEUploader(transferService: BackgroundTransferService(session: session))
        } else {
            self.uploader = E2EEUploader(transferService: .shared)
        }
    }

    // MARK: - Upload (file URL — manual UploadSheet entry point)

    /// Reads `fileURL`, sniffs its MIME type, and delegates to the `Data`-based primitive.
    /// This is a thin wrapper — behaviour (including the `isUploading`/`progress` UI state
    /// consumed by `UploadSheet`) is unchanged.
    func upload(fileURL: URL, parentFolderID: String?) async throws -> UploadResult {
        logger.debug("upload: file=\(fileURL.lastPathComponent, privacy: .public) folder=\(parentFolderID ?? "root", privacy: .public)")

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

        return try await upload(data: plainData, fileName: fileName, mimeType: plainMimeType,
                                parentFolderID: parentFolderID, reportsProgress: true)
    }

    // MARK: - Upload (Data — shared primitive)

    /// Encrypt `data` locally, upload the ciphertext, and store the sealed DEK.
    ///
    /// - Parameter reportsProgress: when `true` (the default, used by the manual `UploadSheet`
    ///   flow), this call publishes `isUploading`/`progress` for that sheet's UI. Background
    ///   photo-sync uploads pass `false` so they don't hijack that sheet's state; callers that
    ///   want their own progress UI should observe their own state instead.
    func upload(data: Data, fileName: String, mimeType: String, parentFolderID: String?,
               reportsProgress: Bool = true) async throws -> UploadResult {

        if reportsProgress {
            isUploading = true
            progress = 0
            error = nil
        }
        defer { if reportsProgress { isUploading = false } }

        // The transfer service reports real bytes-sent from its delegate queue, so `progress`
        // now advances smoothly instead of jumping 0 → 1. Published state must only be touched
        // on the main actor, hence the hop.
        let progressHandler: ((Double) -> Void)? = reportsProgress
            ? { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    // Clamp below 1: the final 1.0 is published only after the sealed key has
                    // been stored, so the sheet never shows "done" while work remains.
                    self.progress = min(fraction, 0.99)
                }
            }
            : nil

        let result = try await uploader.upload(
            data: data,
            fileName: fileName,
            mimeType: mimeType,
            parentFolderID: parentFolderID,
            progress: progressHandler
        )

        driveService?.fileWasUploaded(result)
        if reportsProgress { progress = 1 }
        return result
    }
}
