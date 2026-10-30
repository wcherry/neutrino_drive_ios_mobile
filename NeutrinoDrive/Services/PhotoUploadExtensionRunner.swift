import Foundation
import Photos
import UIKit
import os.log

// MARK: - PhotoExtensionRun

/// What one launch of the Photos background-upload extension did. Kept so the questions the
/// extension's spike asks — how often iOS runs it, for how long, and to what effect — can be
/// read off a device. See `agent_docs/plans/2026-10-09-photo-sync-extension-wakeup.md`.
struct PhotoExtensionRun: Codable, Equatable {
    var startedAt: Date
    var endedAt: Date
    /// Photos newly added to the queue.
    var enqueued = 0
    /// Uploads handed to the extension's background session, or collected from an earlier one.
    var handedOff = 0
    /// Uploads whose result reached this run.
    var completed = 0
    var failed = 0
    /// Over ``PhotoUploadExtensionRunner/maxAssetBytes``; left for the app.
    var leftForApp = 0
    /// In iCloud only; a download was asked for, and the photo is tried on a later run.
    var awaitingDownload = 0
    /// Whether there was work left that this run did not get to.
    var moreToDo = false
    /// Whether iOS asked the extension to stop before the run finished.
    var terminated = false
    /// Why the run did nothing, when it did nothing.
    var skipped: String?

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

// MARK: - PhotoExtensionRunLog

/// The last ``capacity`` runs of the Photos extension, as JSON in the App Group container.
///
/// Only the extension writes it and only the Settings screen reads it, so a whole-file atomic
/// write is enough; no lock.
final class PhotoExtensionRunLog {

    static let capacity = 100
    static let fileName = "photo-extension-runs.json"

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? PhotoSyncStorage.directory.appendingPathComponent(Self.fileName)
    }

    /// Oldest first.
    func runs() -> [PhotoExtensionRun] {
        guard let data = try? Data(contentsOf: fileURL),
              let runs = try? JSONDecoder.photoSync.decode([PhotoExtensionRun].self, from: data) else {
            return []
        }
        return runs
    }

    func append(_ run: PhotoExtensionRun) {
        let runs = (self.runs() + [run]).suffix(Self.capacity)
        guard let data = try? JSONEncoder.photoSync.encode(Array(runs)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - PhotoUploadExtensionRunner

/// What the Photos background-upload extension does each time iOS launches it: take in the
/// photos taken since the app last ran, and hand as many as it can to a background session.
///
/// The same pipeline as `PhotoSyncService`'s drain, cut down to what an extension can do and
/// should do with an unknown, short budget:
///
/// - It never resolves the destination folder or `PATCH`es dates. It has no `DriveService`;
///   without a cached folder it does nothing, and the server stores the dates sent with the
///   upload.
/// - It exports without network access. An original in iCloud only gets a download-only job
///   instead, so the system fetches it on its own schedule and a later run finds it local.
/// - It leaves anything over ``maxAssetBytes`` to the app, which has the memory for it.
/// - It returns once everything it could prepare is handed off. The transfers are iOS's from
///   then on, and their results reach the app if the extension is gone when they land.
///
/// The app drains the same queue, so every entry is claimed on disk before any work is done
/// on it — see ``PhotoSyncQueue/Handoff``.
///
/// Compiled into the app as well as the extension, so it is unit-tested with the app's tests.
@MainActor
final class PhotoUploadExtensionRunner {

    /// The largest asset the extension prepares. Its memory limit is undocumented and
    /// encryption holds about three copies of a photo; 32 MB covers every still a phone takes
    /// short of ProRAW, and leaves videos to the app.
    static let maxAssetBytes: Int64 = 32 * 1024 * 1024

    /// As in the app: bounds the temp files and keeps late transfers inside the token lifetime.
    var maxTransfersInFlight = 12

    // MARK: - Dependencies (real defaults; tests replace them)

    var isFeatureEnabled: () -> Bool = { FeatureFlags.photoAutoSync && FeatureFlags.photoUploadExtension }
    var hasFullLibraryAccess: () -> Bool = {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }
    var hasAccessTokenProvider: () -> Bool = { SharedStorage.accessToken() != nil }
    var hasStoredKeysProvider: () -> Bool = { SharedStorage.hasStoredKeys() }
    var isUnpluggedProvider: () -> Bool = {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return UIDevice.current.batteryState == .unplugged
    }
    var isLowPowerModeEnabledProvider: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Assets created on or after a date, as the app's live observer fetches them.
    var assetsCreatedSince: (Date) -> [PhotoAssetProviding] = { cutoff in
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", cutoff as NSDate)
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PhotoAssetProviding] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// The size of an asset's original, or `nil` when it cannot be told without reading it.
    var assetSizeProvider: (String) -> Int64? = { _ in nil }

    /// Asks the system to bring an iCloud-only original onto the device.
    var downloadRequester: (String) async -> Void = { _ in }

    var tokenRefresher: (() async -> Void)?
    var uploadPreparer: ((PhotoUploadRequest) async throws -> PhotoUploadSubmission)?
    var earlierUploadCollector: ((String) async -> PhotoUploadSubmission?)?
    var now: () -> Date = Date.init

    // MARK: - State

    private let defaults: UserDefaults
    private let queueStore: PhotoSyncQueueStore
    private let assetExporter: PhotoAssetExporting
    private let runLog: PhotoExtensionRunLog
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "PhotoUploadExtensionRunner")

    private var inFlight: Set<String> = []
    /// Entries this run decided not to prepare: claimed by the app, too big, or in iCloud.
    private var passedOver: Set<String> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false
    /// The run under way, or the last one — results that land after it returned are counted
    /// into the next one's log line instead.
    private var current = PhotoExtensionRun(startedAt: .distantPast, endedAt: .distantPast)

    init(defaults: UserDefaults = PhotoSyncDefaults.shared,
         queueStore: PhotoSyncQueueStore = PhotoSyncQueueStore(),
         assetExporter: PhotoAssetExporting = PHKitAssetExporter(),
         runLog: PhotoExtensionRunLog = PhotoExtensionRunLog()) {
        self.defaults = defaults
        self.queueStore = queueStore
        self.assetExporter = assetExporter
        self.runLog = runLog
    }

    /// Wires the upload seams to `uploader`, which sends on the extension's own session.
    func configure(uploader: E2EEUploader) {
        uploadPreparer = { request in
            let prepared = try await uploader.prepare(
                data: request.export.data, fileName: request.export.fileName,
                mimeType: request.export.mimeType, parentFolderID: request.parentFolderID,
                thumbnailBase64: request.export.thumbnailBase64, uploadID: request.uploadID,
                importMetadata: request.importMetadata,
                allowsExpensiveNetworkAccess: request.allowsExpensiveNetworkAccess
            )
            return { try await uploader.submit(prepared) }
        }
        earlierUploadCollector = { uploadID in
            guard await uploader.hasEarlierUpload(uploadID: uploadID) else { return nil }
            return {
                guard let result = try await uploader.earlierUpload(uploadID: uploadID) else {
                    throw EarlierUploadVanished()
                }
                return result
            }
        }
    }

    /// iOS is about to end the extension. The run stops preparing and returns.
    func cancel() {
        cancelled = true
        current.terminated = true
        wake()
    }

    // MARK: - Run

    /// One launch's worth of work. Returns what it did, which is also appended to the run log.
    @discardableResult
    func run() async -> PhotoExtensionRun {
        cancelled = false
        passedOver = []
        current = PhotoExtensionRun(startedAt: now(), endedAt: now())

        if let reason = await work() {
            current.skipped = reason
            logger.info("run skipped: \(reason, privacy: .public)")
        }
        current.endedAt = now()
        runLog.append(current)
        return current
    }

    /// The run itself. Returns why it did nothing, or `nil` once it has done what it could.
    private func work() async -> String? {
        guard isFeatureEnabled() else { return "extension turned off" }
        guard defaults.bool(forKey: PhotoSyncKeys.enabled) else { return "photo sync off" }
        guard hasFullLibraryAccess() else { return "no full photo library access" }
        guard let anchor = defaults.object(forKey: PhotoSyncKeys.anchorDate) as? Date else {
            return "photo sync never started"
        }

        // Taken in even when nothing can be sent, so the app finds them queued.
        enqueueNewAssets(since: anchor)

        guard hasAccessTokenProvider() else { return "signed out" }
        guard hasStoredKeysProvider() else { return "no encryption key" }
        if defaults.object(forKey: PhotoSyncKeys.whileChargingOnly) as? Bool ?? false,
           isUnpluggedProvider() {
            return "waiting to charge"
        }
        if isLowPowerModeEnabledProvider() { return "Low Power Mode" }
        guard let folderID = defaults.string(forKey: PhotoSyncKeys.folderID) else {
            return "destination folder not resolved yet"
        }

        if nextEntry(newerThan: anchor) != nil {
            await tokenRefresher?()
        }

        while !cancelled {
            // A 404 clears the folder; everything else in this run would go to the same one.
            guard defaults.string(forKey: PhotoSyncKeys.folderID) == folderID else { break }
            if inFlight.count >= maxTransfersInFlight {
                await waitForEvent()
                continue
            }
            guard let entry = nextEntry(newerThan: anchor) else { break }
            await start(entry, folderID: folderID)
        }
        current.moreToDo = nextEntry(newerThan: anchor) != nil
        return nil
    }

    private func enqueueNewAssets(since anchor: Date) {
        let assets = assetsCreatedSince(anchor)
        let includeVideos = defaults.object(forKey: PhotoSyncKeys.includeVideos) as? Bool ?? true
        current.enqueued += queueStore.update { queue -> Int in
            let newOnes = PhotoSyncRules.newIdentifiers(from: assets, anchorDate: anchor,
                                                        includeVideos: includeVideos, queue: queue)
            for entry in newOnes {
                queue.enqueue(id: entry.id, creationDate: entry.creationDate,
                              modificationDate: entry.modificationDate)
            }
            return newOnes.count
        }
    }

    /// The next entry this run may take, newest photos first as in the app's drain.
    private func nextEntry(newerThan anchor: Date) -> PhotoSyncQueue.Entry? {
        queueStore.load()
            .drainable(asOf: now(), newerThan: anchor, for: .photosExtension)
            .first { !inFlight.contains($0.id) && !passedOver.contains($0.id) }
    }

    // MARK: - Per entry

    private func start(_ entry: PhotoSyncQueue.Entry, folderID: String) async {
        let claimed = queueStore.update { queue -> Bool in
            guard let current = queue.pending.first(where: { $0.id == entry.id }),
                  !queue.isClaimed(current, byAnotherThan: .photosExtension, asOf: now()) else {
                return false
            }
            queue.markHandedOff(id: entry.id, to: .photosExtension, at: now())
            return true
        }
        guard claimed else {
            passedOver.insert(entry.id)
            return
        }

        let submission: PhotoUploadSubmission
        do {
            guard let prepared = try await prepare(entry, folderID: folderID) else { return }
            submission = prepared
        } catch {
            record(entry, failure: error)
            return
        }

        inFlight.insert(entry.id)
        current.handedOff += 1
        Task {
            let outcome: Result<UploadResult, Error>
            do {
                outcome = .success(try await submission())
            } catch {
                outcome = .failure(error)
            }
            finish(entry, outcome: outcome)
        }
    }

    /// The submission for `entry`, or `nil` when it was passed over for the app or for iCloud.
    private func prepare(_ entry: PhotoSyncQueue.Entry, folderID: String) async throws -> PhotoUploadSubmission? {
        let uploadID = PhotoSyncRules.uploadID(forAssetIdentifier: entry.id)
        if let earlier = await earlierUploadCollector?(uploadID) {
            return earlier
        }

        if let size = assetSizeProvider(entry.id), size > Self.maxAssetBytes {
            leaveForApp(entry)
            return nil
        }

        let export: PhotoExport
        do {
            export = try await assetExporter.exportData(
                for: entry.id,
                includeVideos: defaults.object(forKey: PhotoSyncKeys.includeVideos) as? Bool ?? true,
                networkAccessAllowed: false
            )
        } catch PhotoExportError.notDownloaded {
            release(entry)
            passedOver.insert(entry.id)
            current.awaitingDownload += 1
            await downloadRequester(entry.id)
            return nil
        }
        // A size the provider could not tell in advance, found out the expensive way.
        if export.data.count > Int(Self.maxAssetBytes) {
            leaveForApp(entry)
            return nil
        }

        guard let uploadPreparer else { throw UploadError.notAuthenticated }
        let wifiOnly = defaults.object(forKey: PhotoSyncKeys.wifiOnly) as? Bool ?? true
        return try await uploadPreparer(PhotoUploadRequest(
            export: export,
            parentFolderID: folderID,
            uploadID: uploadID,
            importMetadata: PhotoSyncRules.importMetadata(for: entry),
            allowsExpensiveNetworkAccess: !wifiOnly
        ))
    }

    private func leaveForApp(_ entry: PhotoSyncQueue.Entry) {
        release(entry)
        passedOver.insert(entry.id)
        current.leftForApp += 1
    }

    private func release(_ entry: PhotoSyncQueue.Entry) {
        queueStore.update { $0.releaseHandoff(id: entry.id) }
    }

    // MARK: - Outcomes

    /// Records how a transfer ended — as the app's drain does, except that a stale folder or
    /// token is left for the next run rather than retried here.
    private func finish(_ entry: PhotoSyncQueue.Entry, outcome: Result<UploadResult, Error>) {
        inFlight.remove(entry.id)
        defer { wake() }

        switch outcome {
        case .success(let result):
            queueStore.update { $0.markCompleted(id: entry.id, fileID: result.id) }
            defaults.set(now(), forKey: PhotoSyncKeys.lastSuccessfulSync)
            current.completed += 1
        // Each of these is left for a later run — passed over in this one, which would only
        // meet the same stale folder or token again.
        case .failure(UploadError.serverError(let code)) where code == 404:
            // The cached folder is gone. The app resolves a new one; until then, nothing here
            // can be sent anywhere.
            defaults.removeObject(forKey: PhotoSyncKeys.folderID)
            release(entry)
            passedOver.insert(entry.id)
        case .failure(UploadError.serverError(let code)) where code == 401:
            release(entry)
            passedOver.insert(entry.id)
        case .failure(is EarlierUploadVanished):
            release(entry)
            passedOver.insert(entry.id)
        case .failure(let error):
            record(entry, failure: error)
        }
    }

    private func record(_ entry: PhotoSyncQueue.Entry, failure error: Error) {
        let permanent = (error as? UploadError).map(PhotoSyncRules.isPermanent) ?? false
        queueStore.update {
            $0.markFailed(id: entry.id, error: error.localizedDescription, permanent: permanent)
        }
        current.failed += 1
        logger.error("\(entry.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Transfers that finish with nobody waiting

    /// Records the outcome of a transfer this process did not start — one an earlier launch of
    /// the extension handed off, whose result iOS delivered to this one.
    func collectFinishedTransfer(transferID: String) async {
        guard let assetID = PhotoSyncRules.assetIdentifier(forTransferID: transferID),
              !inFlight.contains(assetID),
              let entry = queueStore.load().pending.first(where: { $0.id == assetID }),
              let collect = await earlierUploadCollector?(PhotoSyncRules.uploadID(forAssetIdentifier: assetID)),
              !inFlight.contains(assetID) else { return }

        inFlight.insert(assetID)
        let outcome: Result<UploadResult, Error>
        do {
            outcome = .success(try await collect())
        } catch {
            outcome = .failure(error)
        }
        finish(entry, outcome: outcome)
    }

    // MARK: - Waiting

    private func waitForEvent() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func wake() {
        let parked = waiters
        waiters.removeAll()
        parked.forEach { $0.resume() }
    }

    #if DEBUG
    /// Waits until no transfer this run handed off is still in flight.
    func debugSettle() async {
        while !inFlight.isEmpty { await waitForEvent() }
    }
    #endif
}
