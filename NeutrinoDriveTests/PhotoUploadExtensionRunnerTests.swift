import XCTest
import Photos
@testable import NeutrinoDrive

private struct RunnerAsset: PhotoAssetProviding {
    let localIdentifier: String
    let creationDate: Date?
    var modificationDate: Date? = nil
    var mediaType: PHAssetMediaType = .image
}

/// Exports canned bytes, or fails the way PhotoKit does for an iCloud-only original.
private final class RunnerExporter: PhotoAssetExporting {
    var inCloudOnly: Set<String> = []
    var bytes = Data("photo".utf8)
    private(set) var exported: [String] = []
    private(set) var networkAccessRequests: [Bool] = []

    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport {
        networkAccessRequests.append(networkAccessAllowed)
        if inCloudOnly.contains(identifier) { throw PhotoExportError.notDownloaded }
        exported.append(identifier)
        return PhotoExport(data: bytes, fileName: "\(identifier).jpg", mimeType: "image/jpeg")
    }
}

private func result(_ id: String) -> UploadResult {
    UploadResult(id: id, name: "IMG.jpg", folderId: "folder-1", sizeBytes: 1,
                 mimeType: "image/jpeg", updatedAt: Date())
}

@MainActor
final class PhotoUploadExtensionRunnerTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: PhotoSyncQueueStore!
    private var log: PhotoExtensionRunLog!
    private var exporter: RunnerExporter!
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "PhotoUploadExtensionRunnerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoUploadExtensionRunnerTests-\(UUID().uuidString)", isDirectory: true)
        store = PhotoSyncQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        log = PhotoExtensionRunLog(fileURL: directory.appendingPathComponent("runs.json"))
        exporter = RunnerExporter()

        defaults.set(true, forKey: PhotoSyncKeys.enabled)
        defaults.set(anchor, forKey: PhotoSyncKeys.anchorDate)
        defaults.set("folder-1", forKey: PhotoSyncKeys.folderID)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A runner whose every precondition holds, sending nothing anywhere.
    private func makeSUT(assets: [PhotoAssetProviding] = []) -> PhotoUploadExtensionRunner {
        let sut = PhotoUploadExtensionRunner(defaults: defaults, queueStore: store,
                                             assetExporter: exporter, runLog: log)
        sut.isFeatureEnabled = { true }
        sut.hasFullLibraryAccess = { true }
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isUnpluggedProvider = { false }
        sut.isLowPowerModeEnabledProvider = { false }
        sut.assetsCreatedSince = { _ in assets }
        sut.uploadPreparer = { request in { result("file-\(request.uploadID)") } }
        return sut
    }

    private func asset(_ id: String, minutesAfterAnchor: Double = 1) -> RunnerAsset {
        RunnerAsset(localIdentifier: id, creationDate: anchor.addingTimeInterval(minutesAfterAnchor * 60))
    }

    // MARK: - Preconditions

    func test_run_doesNothingWhileTheFeatureIsOff() async {
        let sut = makeSUT(assets: [asset("asset-1")])
        sut.isFeatureEnabled = { false }

        let run = await sut.run()

        XCTAssertEqual(run.skipped, "extension turned off")
        XCTAssertTrue(store.load().pending.isEmpty)
    }

    func test_run_doesNothingWithoutFullLibraryAccess() async {
        let sut = makeSUT(assets: [asset("asset-1")])
        sut.hasFullLibraryAccess = { false }

        let run = await sut.run()

        XCTAssertEqual(run.skipped, "no full photo library access")
    }

    /// Signed out, it can still note what was taken — the app finds it queued.
    func test_run_signedOut_stillEnqueuesButSendsNothing() async {
        let sut = makeSUT(assets: [asset("asset-1")])
        sut.hasAccessTokenProvider = { false }
        sut.uploadPreparer = { _ in XCTFail("nothing may be sent signed out"); throw UploadError.notAuthenticated }

        let run = await sut.run()

        XCTAssertEqual(run.skipped, "signed out")
        XCTAssertEqual(run.enqueued, 1)
        XCTAssertEqual(store.load().pending.map(\.id), ["asset-1"])
    }

    /// The extension cannot create the folder; the app does that on its next run.
    func test_run_withoutACachedFolder_leavesTheWorkForTheApp() async {
        defaults.removeObject(forKey: PhotoSyncKeys.folderID)
        let sut = makeSUT(assets: [asset("asset-1")])

        let run = await sut.run()

        XCTAssertEqual(run.skipped, "destination folder not resolved yet")
        XCTAssertTrue(exporter.exported.isEmpty)
    }

    func test_run_whileChargingOnlyAndUnplugged_sendsNothing() async {
        defaults.set(true, forKey: PhotoSyncKeys.whileChargingOnly)
        let sut = makeSUT(assets: [asset("asset-1")])
        sut.isUnpluggedProvider = { true }

        let run = await sut.run()

        XCTAssertEqual(run.skipped, "waiting to charge")
    }

    // MARK: - The run

    func test_run_enqueuesNewPhotosAndHandsThemOff() async {
        let sut = makeSUT(assets: [asset("asset-1"), asset("asset-2", minutesAfterAnchor: 2)])

        let run = await sut.run()
        await sut.debugSettle()

        XCTAssertNil(run.skipped)
        XCTAssertEqual(run.enqueued, 2)
        XCTAssertEqual(run.handedOff, 2)
        XCTAssertFalse(run.moreToDo)
        let queue = store.load()
        XCTAssertEqual(queue.completedFileID(for: "asset-1"), "file-photo-sync:asset-1")
        XCTAssertEqual(queue.completedFileID(for: "asset-2"), "file-photo-sync:asset-2")
    }

    /// Before the anchor is the backfill's job, and the app's.
    func test_run_ignoresPhotosOlderThanTheAnchor() async {
        let sut = makeSUT(assets: [asset("old", minutesAfterAnchor: -60)])

        let run = await sut.run()

        XCTAssertEqual(run.enqueued, 0)
    }

    func test_run_exportsWithoutTheNetwork() async {
        let sut = makeSUT(assets: [asset("asset-1")])

        await sut.run()

        XCTAssertEqual(exporter.networkAccessRequests, [false])
    }

    func test_run_claimsEachEntryBeforeSendingIt() async {
        let sut = makeSUT(assets: [asset("asset-1")])
        var claimAtSend: PhotoSyncQueue.Handoff.Owner?
        sut.uploadPreparer = { [store] request in
            claimAtSend = store!.load().pending.first?.handoff?.owner
            return { result("file-1") }
        }

        await sut.run()

        XCTAssertEqual(claimAtSend, .photosExtension)
    }

    func test_run_leavesAnEntryTheAppClaimed() async {
        store.update {
            $0.enqueue(id: "asset-1", creationDate: anchor.addingTimeInterval(60))
            $0.markHandedOff(id: "asset-1", to: .app)
        }
        let sut = makeSUT()
        sut.uploadPreparer = { _ in XCTFail("the app is sending this one"); throw UploadError.encryptionFailed }

        let run = await sut.run()

        XCTAssertEqual(run.handedOff, 0)
        XCTAssertEqual(store.load().pending.first?.handoff?.owner, .app)
    }

    func test_run_passesTheWifiOnlySettingToTheRequest() async {
        defaults.set(true, forKey: PhotoSyncKeys.wifiOnly)
        let sut = makeSUT(assets: [asset("asset-1")])
        var allowsExpensive: Bool?
        sut.uploadPreparer = { request in
            allowsExpensive = request.allowsExpensiveNetworkAccess
            return { result("file-1") }
        }

        await sut.run()

        XCTAssertEqual(allowsExpensive, false)
    }

    func test_run_sendsTheCaptureDatesWithTheUpload() async {
        let sut = makeSUT(assets: [asset("asset-1")])
        var metadata: DriveImportMetadata?
        sut.uploadPreparer = { request in
            metadata = request.importMetadata
            return { result("file-1") }
        }

        await sut.run()

        XCTAssertEqual(metadata?.createdAt, anchor.addingTimeInterval(60))
        XCTAssertEqual(metadata?.importSource, "photo-sync:asset-1")
    }

    func test_run_neverHasMoreThanTheCapInFlight() async {
        let assets = (1...5).map { asset("asset-\($0)", minutesAfterAnchor: Double($0)) }
        let sut = makeSUT(assets: assets)
        sut.maxTransfersInFlight = 2
        var live = 0
        var peak = 0
        sut.uploadPreparer = { request in
            {
                live += 1
                peak = max(peak, live)
                await Task.yield()
                live -= 1
                return result("file-\(request.uploadID)")
            }
        }

        let run = await sut.run()
        await sut.debugSettle()

        XCTAssertEqual(run.handedOff, 5)
        XCTAssertLessThanOrEqual(peak, 2)
    }

    // MARK: - Passed over

    func test_run_leavesAnAssetOverTheCapForTheApp() async {
        let sut = makeSUT(assets: [asset("big")])
        sut.assetSizeProvider = { _ in PhotoUploadExtensionRunner.maxAssetBytes + 1 }

        let run = await sut.run()

        XCTAssertEqual(run.leftForApp, 1)
        XCTAssertTrue(exporter.exported.isEmpty, "the size was known; nothing should have been read")
        let entry = store.load().pending.first
        XCTAssertEqual(entry?.id, "big")
        XCTAssertNil(entry?.handoff, "unclaimed, so the app takes it at once")
        XCTAssertEqual(entry?.attempts, 0)
    }

    func test_run_asksForTheDownloadOfAnICloudOnlyOriginal() async {
        exporter.inCloudOnly = ["cloud"]
        let sut = makeSUT(assets: [asset("cloud")])
        var requested: [String] = []
        sut.downloadRequester = { requested.append($0) }

        let run = await sut.run()

        XCTAssertEqual(requested, ["cloud"])
        XCTAssertEqual(run.awaitingDownload, 1)
        let entry = store.load().pending.first
        XCTAssertEqual(entry?.attempts, 0, "waiting for iCloud is not a failed attempt")
        XCTAssertNil(entry?.handoff)
    }

    // MARK: - Outcomes

    func test_run_aFailedPreparationCostsAnAttempt() async {
        let sut = makeSUT(assets: [asset("asset-1")])
        sut.uploadPreparer = { _ in throw UploadError.encryptionFailed }

        let run = await sut.run()

        XCTAssertEqual(run.failed, 1)
        XCTAssertEqual(store.load().pending.first?.attempts, 1)
    }

    func test_run_aStaleFolderIsClearedForTheAppToResolve() async {
        let sut = makeSUT(assets: [asset("asset-1")])
        sut.uploadPreparer = { _ in { throw UploadError.serverError(statusCode: 404) } }

        await sut.run()
        await sut.debugSettle()

        XCTAssertNil(defaults.string(forKey: PhotoSyncKeys.folderID))
        let entry = store.load().pending.first
        XCTAssertEqual(entry?.attempts, 0)
        XCTAssertNil(entry?.handoff)
    }

    func test_run_collectsAnEarlierUploadInsteadOfExporting() async {
        let sut = makeSUT(assets: [asset("asset-1")])
        sut.earlierUploadCollector = { _ in { result("file-from-before") } }

        await sut.run()
        await sut.debugSettle()

        XCTAssertTrue(exporter.exported.isEmpty)
        XCTAssertEqual(store.load().completedFileID(for: "asset-1"), "file-from-before")
    }

    func test_collectFinishedTransfer_recordsAResultFromAnEarlierLaunch() async {
        store.update { $0.enqueue(id: "asset-1", creationDate: anchor.addingTimeInterval(60)) }
        let sut = makeSUT()
        sut.earlierUploadCollector = { _ in { result("file-delivered") } }

        let transferID = E2EEUploader.blobTransferID(
            uploadID: PhotoSyncRules.uploadID(forAssetIdentifier: "asset-1"))
        await sut.collectFinishedTransfer(transferID: transferID)

        XCTAssertEqual(store.load().completedFileID(for: "asset-1"), "file-delivered")
    }

    // MARK: - Expiry and the log

    func test_cancel_stopsTheRunWhileItWaitsForASlot() async {
        let assets = (1...3).map { asset("asset-\($0)", minutesAfterAnchor: Double($0)) }
        let sut = makeSUT(assets: assets)
        sut.maxTransfersInFlight = 1
        var release: CheckedContinuation<Void, Never>?
        sut.uploadPreparer = { _ in
            {
                await withCheckedContinuation { release = $0 }
                return result("file")
            }
        }

        let running = Task { await sut.run() }
        while release == nil { await Task.yield() }
        sut.cancel()
        let run = await running.value
        release?.resume()

        XCTAssertTrue(run.terminated)
        XCTAssertTrue(run.moreToDo)
        XCTAssertEqual(run.handedOff, 1)
    }

    func test_run_isAppendedToTheLog() async {
        let sut = makeSUT(assets: [asset("asset-1")])

        await sut.run()
        await sut.run()

        let runs = log.runs()
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first?.enqueued, 1)
    }

    func test_log_keepsOnlyTheMostRecentRuns() {
        // Whole seconds: the log stores ISO 8601, which drops the fraction.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<(PhotoExtensionRunLog.capacity + 5) {
            let at = start.addingTimeInterval(Double(i))
            log.append(PhotoExtensionRun(startedAt: at, endedAt: at))
        }

        let runs = log.runs()
        XCTAssertEqual(runs.count, PhotoExtensionRunLog.capacity)
        XCTAssertEqual(runs.last?.startedAt, start.addingTimeInterval(Double(PhotoExtensionRunLog.capacity + 4)))
    }
}
