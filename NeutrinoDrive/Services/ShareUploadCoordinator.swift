import Foundation
import UniformTypeIdentifiers
import os.log

// MARK: - ShareLimits

enum ShareLimits {

    /// Maximum plaintext size the share extension will accept, in bytes.
    ///
    /// **Why this is so much smaller than the app's 512 MB photo-sync cap.** A share extension
    /// is killed at a far lower resident footprint than its host app — on the order of 120 MB,
    /// versus the several hundred available to the app. And the encrypt-and-POST pipeline holds
    /// roughly three copies of the payload at peak: the plaintext `Data`, the secretstream
    /// ciphertext, and the assembled multipart body. So the real ceiling is about
    /// `limit x 3 + overhead`.
    ///
    /// 25 MB gives a ~75 MB peak with headroom to spare. Raising it meaningfully requires
    /// streaming (chunked) encryption straight to the body file, which is the same follow-up
    /// the photo-sync plan names under "Memory" — not something to fake with a bigger number.
    ///
    /// This is an engineering estimate, not a measured device limit; exceeding it manifests as
    /// a jetsam kill with no error visible to the user, which is precisely why the cap is
    /// enforced *before* the bytes are read.
    static let maxItemBytes: Int64 = 25 * 1024 * 1024

    static let oversizeMessage = "Too large to share — upload it from the Neutrino Drive app instead."
}

// MARK: - ShareAttachment

/// One item the user shared. Abstracted over `NSItemProvider` so the coordinator's sequencing,
/// size-gating, and error-isolation logic can be unit-tested without a share sheet.
protocol ShareAttachment {
    /// Best-effort display name, used for the result list and as the upload filename.
    var suggestedName: String { get }

    /// Materialises the attachment as a **file on disk**, without loading it into memory.
    ///
    /// This is `loadFileRepresentation`, not `loadDataRepresentation`, specifically so the size
    /// check can happen against the file's attributes before a single byte is allocated. Doing
    /// it the other way round would mean a 400 MB video is already resident by the time it is
    /// rejected for being too large.
    func loadFile() async throws -> URL
}

// MARK: - ShareItemOutcome

enum ShareItemOutcome: Equatable {
    case uploaded(id: String)
    case failed(message: String)

    var isSuccess: Bool {
        if case .uploaded = self { return true }
        return false
    }
}

struct ShareItemResult: Equatable {
    let name: String
    let outcome: ShareItemOutcome
}

// MARK: - ShareUploadError

enum ShareUploadError: LocalizedError, Equatable {
    case notAuthenticated
    case noEncryptionKey
    case noItems

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Sign in to Neutrino Drive before sharing files."
        case .noEncryptionKey:  return "Import your encryption key in Neutrino Drive before sharing files."
        case .noItems:          return "Nothing to upload."
        }
    }
}

// MARK: - ShareUploadCoordinator

/// Drives the share extension's upload run: preconditions, then each attachment in turn.
///
/// Compiled into **both** the app target (so it is unit-testable, and so the shared source set
/// stays one list rather than two) and the extension target.
///
/// Sequential, not concurrent, and deliberately so: parallel uploads multiply the peak memory
/// that ``ShareLimits/maxItemBytes`` exists to bound, in an extension that has far less of it
/// than the host app.
final class ShareUploadCoordinator {

    private let uploader: E2EEUploader
    private let maxItemBytes: Int64
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDriveShare",
                                category: "ShareUploadCoordinator")

    /// Injected so tests need neither the Keychain nor a network. Defaults to the real
    /// Keychain-backed checks.
    var hasStoredKeysProvider: () -> Bool = { SharedStorage.hasStoredKeys() }
    var hasAccessTokenProvider: () -> Bool = { SharedStorage.accessToken() != nil }

    /// Overridable upload hook. Production wires it to `E2EEUploader`; tests substitute a fake
    /// so no bytes leave the process.
    var uploadHandler: ((Data, String, String, String?) async throws -> UploadResult)?

    /// Reports the file size at `url`. Injectable so oversize rejection can be tested without
    /// producing a genuinely enormous fixture file.
    var fileSizeProvider: (URL) -> Int64? = { url in
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    init(uploader: E2EEUploader = E2EEUploader(),
         maxItemBytes: Int64 = ShareLimits.maxItemBytes) {
        self.uploader = uploader
        self.maxItemBytes = maxItemBytes
        self.uploadHandler = { [uploader] data, name, mime, folder in
            try await uploader.upload(data: data, fileName: name, mimeType: mime,
                                      parentFolderID: folder, progress: nil)
        }
    }

    // MARK: - Preconditions

    /// Checked once, before any attachment is touched.
    ///
    /// The extension cannot present the login or key-import flow — it has no access to the
    /// app's navigation — so failing fast with an explanation and an "Open Neutrino Drive"
    /// affordance is the only honest outcome. Silently queueing for later would be worse: the
    /// extension's process dies the moment it is dismissed, taking the queue with it.
    func checkPreconditions(attachmentCount: Int) -> ShareUploadError? {
        guard attachmentCount > 0 else { return .noItems }
        guard hasAccessTokenProvider() else { return .notAuthenticated }
        guard hasStoredKeysProvider() else { return .noEncryptionKey }
        return nil
    }

    // MARK: - Run

    /// Uploads each attachment in order, returning one result per attachment.
    ///
    /// One failure never aborts the run — a user who shares five photos and hits a server error
    /// on the third should still get the other four, and should be told exactly which one
    /// failed.
    func run(attachments: [ShareAttachment],
             parentFolderID: String? = nil,
             onProgress: ((Int, Int) -> Void)? = nil) async -> [ShareItemResult] {

        var results: [ShareItemResult] = []
        let total = attachments.count

        for (index, attachment) in attachments.enumerated() {
            onProgress?(index + 1, total)
            results.append(await upload(attachment))
        }
        return results
    }

    private func upload(_ attachment: ShareAttachment) async -> ShareItemResult {
        let name = attachment.suggestedName

        let fileURL: URL
        do {
            fileURL = try await attachment.loadFile()
        } catch {
            logger.error("loadFile failed for \(name, privacy: .public): \(error, privacy: .public)")
            return ShareItemResult(name: name, outcome: .failed(message: error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Size gate happens here — against file attributes, before `Data(contentsOf:)`.
        if let size = fileSizeProvider(fileURL), size > maxItemBytes {
            logger.info("rejecting \(name, privacy: .public): \(size) bytes exceeds cap")
            return ShareItemResult(name: name, outcome: .failed(message: ShareLimits.oversizeMessage))
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            return ShareItemResult(name: name, outcome: .failed(message: error.localizedDescription))
        }

        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"

        do {
            guard let uploadHandler else {
                return ShareItemResult(name: name, outcome: .failed(message: UploadError.notAuthenticated.localizedDescription))
            }
            let result = try await uploadHandler(data, name, mimeType, nil)
            return ShareItemResult(name: name, outcome: .uploaded(id: result.id))
        } catch {
            logger.error("upload failed for \(name, privacy: .public): \(error, privacy: .public)")
            return ShareItemResult(name: name, outcome: .failed(message: error.localizedDescription))
        }
    }
}

// MARK: - ItemProviderAttachment

/// Production ``ShareAttachment`` backed by `NSItemProvider`.
struct ItemProviderAttachment: ShareAttachment {

    let provider: NSItemProvider
    let typeIdentifier: String

    var suggestedName: String {
        provider.suggestedName ?? "Shared \(Int(Date().timeIntervalSince1970))"
    }

    func loadFile() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(throwing: UploadError.fileReadError(
                        underlying: NSError(domain: "ShareExtension", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "The shared item could not be read."])
                    ))
                    return
                }
                // The URL handed to this callback is deleted as soon as the closure returns,
                // so copy it somewhere we own before resuming.
                do {
                    let destDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("nd-share-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                    let dest = destDir.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
