import Foundation
import ExtensionFoundation
import Photos
import os.log
import NeutrinoCore
import NeutrinoAuth

// MARK: - PhotoUploadExtension

/// The Photos background-upload extension (#38, Phase 2): iOS launches it when the photo library
/// changes, which is the wake-up photo sync otherwise has to wait hours for.
///
/// It never creates an upload job for a photo. The system would upload the original,
/// unencrypted bytes, and nothing in the API lets the app encrypt them first. Instead it runs
/// photo sync's own prepare stage — see ``PhotoUploadExtensionRunner`` — and sends the encrypted
/// bodies on a background session of its own. The only jobs it creates are download-only ones,
/// for originals still in iCloud.
@main
final class PhotoUploadExtension: PHBackgroundResourceUploadJobExtension {

    /// One background session per process, and this process is the extension.
    private static let transfers = BackgroundTransferService.forPhotosExtension()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrivePhotoUpload",
                                category: "PhotoUploadExtension")

    @MainActor private var runner: PhotoUploadExtensionRunner?

    required init() {
        // Before anything reads the Keychain or the App Group: both resolve through it.
        NeutrinoApp.configure(.drive)
        KeychainService.reloadAccessGroup()
    }

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        await acknowledgeFinishedJobs()
        let run = await runOnce()
        logger.info("""
            run: \(run.handedOff) handed off, \(run.completed) completed, \(run.enqueued) enqueued, \
            \(run.awaitingDownload) awaiting download, \(run.leftForApp) left for the app, \
            more=\(run.moreToDo), skipped=\(run.skipped ?? "-", privacy: .public)
            """)
        // `.processing` asks iOS to call again; `.completed` says the library is caught up.
        return run.moreToDo ? .processing : .completed
    }

    func willTerminate() async {
        await MainActor.run { runner?.cancel() }
    }

    @MainActor
    private func runOnce() async -> PhotoExtensionRun {
        let runner = self.runner ?? makeRunner()
        self.runner = runner
        return await runner.run()
    }

    @MainActor
    private func makeRunner() -> PhotoUploadExtensionRunner {
        let runner = PhotoUploadExtensionRunner()
        runner.configure(uploader: E2EEUploader(transferService: Self.transfers,
                                                deliveredTransfers: { [] }))
        runner.tokenRefresher = { await AuthService().refreshTokenIfNeeded() }
        runner.assetSizeProvider = { identifier in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
                  let resource = PHKitAssetExporter.primaryResource(for: asset),
                  let size = resource.dataSize else { return nil }
            return Int64(size)
        }
        runner.downloadRequester = { [weak self] identifier in
            await self?.requestDownload(of: identifier)
        }
        // Results an earlier launch handed off, delivered to this one.
        Self.transfers.setOrphanHandler { [weak runner] transferID in
            Task { @MainActor in await runner?.collectFinishedTransfer(transferID: transferID) }
        }
        return runner
    }

    // MARK: - Download-only jobs

    /// Asks the system to bring an iCloud-only original onto the device, unless a job for it is
    /// already waiting. A later run then exports it without the network.
    private func requestDownload(of identifier: String) async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let resource = PHKitAssetExporter.primaryResource(for: asset) else { return }
        let waiting = PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil)
        var alreadyRequested = false
        waiting.enumerateObjects { job, _, stop in
            if PHAssetResource.assetResource(forUploadJob: job)?.assetLocalIdentifier == identifier {
                alreadyRequested = true
                stop.pointee = true
            }
        }
        guard !alreadyRequested else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetResourceUploadJobChangeRequest.creationRequestForDownloadJob(resource: resource)
            }
        } catch {
            // Most likely the job limit; the photo is simply tried again on a later run.
            logger.error("download job for \(identifier, privacy: .public) refused: \(error, privacy: .public)")
        }
    }

    /// Acknowledges finished download jobs. Unacknowledged ones count against
    /// `PHAssetResourceUploadJob.jobLimit`, and at the limit no new download can be asked for.
    private func acknowledgeFinishedJobs() async {
        let finished = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
        guard finished.count > 0 else { return }
        var jobs: [PHAssetResourceUploadJob] = []
        finished.enumerateObjects { job, _, _ in jobs.append(job) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for job in jobs {
                    PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
                }
            }
        } catch {
            logger.error("could not acknowledge finished jobs: \(error, privacy: .public)")
        }
    }
}
