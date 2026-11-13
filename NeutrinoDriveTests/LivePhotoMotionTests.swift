import XCTest
import Photos
@testable import NeutrinoDrive

// MARK: - Fakes

private struct LiveAsset: PhotoAssetProviding {
    let localIdentifier: String
    let creationDate: Date?
    var modificationDate: Date?
    var mediaType: PHAssetMediaType = .image
    var mediaSubtypes: PHAssetMediaSubtype = .photoLive
}

/// Hands back a still or a clip, and records which it was asked for.
private final class MotionExporter: PhotoAssetExporting {
    var stillCalls: [String] = []
    var clipCalls: [String] = []
    /// Assets with no clip to give.
    var withoutClip: Set<String> = []

    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport {
        stillCalls.append(identifier)
        return PhotoExport(data: Data("still".utf8), fileName: "IMG_0001.HEIC", mimeType: "image/heic")
    }

    func exportPairedVideo(for identifier: String,
                           networkAccessAllowed: Bool) async throws -> PhotoExport {
        clipCalls.append(identifier)
        if withoutClip.contains(identifier) { throw PhotoExportError.noPairedVideo }
        return PhotoExport(data: Data("clip".utf8), fileName: "IMG_0001.MOV", mimeType: "video/quicktime",
                           thumbnailBase64: "POSTER")
    }
}

private struct FakeMotionAssets: LivePhotoMotionAssetProviding {
    var assets: [String: LivePhotoMotionAsset]
    func assets(forIdentifiers identifiers: [String]) -> [String: LivePhotoMotionAsset] {
        assets.filter { identifiers.contains($0.key) }
    }
}

private func clip(_ stem: String, bytes: Int64? = 2_000_000, created: Date = Date(timeIntervalSince1970: 1_000)) -> LivePhotoMotionAsset {
    .live(LivePhotoClip(creationDate: created, modificationDate: nil,
                        stillName: "\(stem).HEIC", clipName: "\(stem).MOV", clipBytes: bytes))
}

private func folderFile(_ id: String, _ name: String) -> DriveFolderFile {
    DriveFolderFile(id: id, name: name, createdAt: nil)
}

// MARK: - Rules

final class LivePhotoMotionRulesTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testMotionEntryIDsRoundTrip() {
        let id = "ABC-123/L0/001"
        let motion = PhotoSyncRules.motionEntryID(forAssetIdentifier: id)
        XCTAssertEqual(motion, "ABC-123/L0/001#motion")
        XCTAssertEqual(PhotoSyncRules.parseEntryID(motion).assetIdentifier, id)
        XCTAssertTrue(PhotoSyncRules.parseEntryID(motion).isMotion)
        XCTAssertFalse(PhotoSyncRules.parseEntryID(id).isMotion)
        XCTAssertEqual(PhotoSyncRules.importSource(forAssetIdentifier: motion), "photo-sync:ABC-123/L0/001#motion")
    }

    func testANewLivePhotoIsQueuedWithItsMotionStillFirst() {
        let entries = PhotoSyncRules.newIdentifiers(
            from: [LiveAsset(localIdentifier: "A", creationDate: t0)],
            anchorDate: .distantPast, includeVideos: true, keepLivePhotoMotion: true, queue: PhotoSyncQueue()
        )
        XCTAssertEqual(entries.map(\.id), ["A", "A#motion"])
        XCTAssertEqual(entries[1].creationDate, t0)
    }

    func testNoMotionWhenTheSettingIsOff() {
        let entries = PhotoSyncRules.newIdentifiers(
            from: [LiveAsset(localIdentifier: "A", creationDate: t0)],
            anchorDate: .distantPast, includeVideos: true, keepLivePhotoMotion: false, queue: PhotoSyncQueue()
        )
        XCTAssertEqual(entries.map(\.id), ["A"])
    }

    func testMotionIsQueuedEvenWithVideosOff() {
        let entries = PhotoSyncRules.newIdentifiers(
            from: [LiveAsset(localIdentifier: "A", creationDate: t0),
                   LiveAsset(localIdentifier: "V", creationDate: t0, mediaType: .video, mediaSubtypes: [])],
            anchorDate: .distantPast, includeVideos: false, keepLivePhotoMotion: true, queue: PhotoSyncQueue()
        )
        XCTAssertEqual(entries.map(\.id), ["A", "A#motion"])
    }

    func testAPlainPhotoGetsNoMotion() {
        let entries = PhotoSyncRules.newIdentifiers(
            from: [LiveAsset(localIdentifier: "A", creationDate: t0, mediaSubtypes: [])],
            anchorDate: .distantPast, includeVideos: true, keepLivePhotoMotion: true, queue: PhotoSyncQueue()
        )
        XCTAssertEqual(entries.map(\.id), ["A"])
    }

    func testAStillAlreadyKnownDoesNotGetMotionFromAScan() {
        // That's the "Add Live Photo Motion" pass's job, which asks first.
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A")
        let entries = PhotoSyncRules.newIdentifiers(
            from: [LiveAsset(localIdentifier: "A", creationDate: t0)],
            anchorDate: .distantPast, includeVideos: true, keepLivePhotoMotion: true, queue: queue
        )
        XCTAssertTrue(entries.isEmpty)
    }

    func testTheDrainTakesAStillBeforeItsMotion() {
        var queue = PhotoSyncQueue()
        queue.enqueue(id: "A#motion", creationDate: t0)
        queue.enqueue(id: "A", creationDate: t0)
        XCTAssertEqual(queue.drainable().map(\.id), ["A", "A#motion"])
    }

    func testTurningMotionOffDropsOnlyWaitingAndFailedMotion() {
        var queue = PhotoSyncQueue()
        queue.enqueue(id: "A", creationDate: t0)
        queue.enqueue(id: "A#motion", creationDate: t0)
        queue.enqueue(id: "B#motion", creationDate: t0)
        queue.markFailed(id: "B#motion", error: "x", permanent: true)
        queue.markCompleted(id: "C#motion", fileID: "f-C")

        queue.removeMotionEntries()

        XCTAssertEqual(queue.pending.map(\.id), ["A"])
        XCTAssertTrue(queue.failed.isEmpty)
        XCTAssertEqual(queue.completedFileID(for: "C#motion"), "f-C", "clips already in Drive stay recorded")
    }

    func testCompactionKeepsMotionWithItsAsset() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "1")
        queue.markCompleted(id: "A#motion", fileID: "2")
        queue.markCompleted(id: "B#motion", fileID: "3")
        queue.compact(keepingIdentifiers: ["A"])
        XCTAssertEqual(Set(queue.completed.keys), ["A", "A#motion"])
    }

    func testTheClipIsNamedAfterItsStill() {
        XCTAssertEqual(PHKitAssetExporter.pairedVideoFileName(stillName: "IMG_1234.HEIC", videoName: "IMG_1234.MOV"),
                       "IMG_1234.MOV")
        XCTAssertEqual(PHKitAssetExporter.pairedVideoFileName(stillName: "IMG_1234.HEIC", videoName: "FullSizeRender.mov"),
                       "IMG_1234.mov")
        XCTAssertEqual(PHKitAssetExporter.pairedVideoFileName(stillName: "IMG_1234.HEIC", videoName: ""),
                       "IMG_1234.MOV")
        XCTAssertEqual(PHKitAssetExporter.pairedVideoFileName(stillName: "Trip.v2.JPG", videoName: "x.MOV"),
                       "Trip.v2.MOV")
    }

    func testExportingAnEntryRoutesMotionToTheClip() async throws {
        let exporter = MotionExporter()
        let still = try await exporter.export(entryID: "A", includeVideos: true, networkAccessAllowed: true)
        let motion = try await exporter.export(entryID: "A#motion", includeVideos: true, networkAccessAllowed: true)
        XCTAssertEqual(still.mimeType, "image/heic")
        XCTAssertEqual(motion.mimeType, "video/quicktime")
        XCTAssertEqual(exporter.stillCalls, ["A"])
        XCTAssertEqual(exporter.clipCalls, ["A"], "the clip is asked for by the asset's own identifier")
    }
}

// MARK: - Backfill planner

final class LivePhotoMotionBackfillPlannerTests: XCTestCase {

    func testQueuesTheMotionOfAnUploadedStillStillInTheFolder() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A")
        let plan = LivePhotoMotionBackfillPlanner.plan(
            queue: queue, assets: ["A": clip("IMG_0001", bytes: 2_500_000)],
            folderFiles: [folderFile("f-A", "IMG_0001.HEIC")]
        )
        XCTAssertEqual(plan.enqueue.map(\.entryID), ["A#motion"])
        XCTAssertEqual(plan.estimatedBytes, 2_500_000)
        XCTAssertEqual(plan.report.queued, 1)
    }

    func testCountsAnUnknownSizeAtATypicalClip() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A")
        let plan = LivePhotoMotionBackfillPlanner.plan(
            queue: queue, assets: ["A": clip("IMG_0001", bytes: nil)],
            folderFiles: [folderFile("f-A", "IMG_0001.HEIC")]
        )
        XCTAssertEqual(plan.estimatedBytes, LivePhotoMotionBackfillPlanner.typicalClipBytes)
    }

    func testLeavesAloneAStillRemovedFromTheFolder() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A")
        let plan = LivePhotoMotionBackfillPlanner.plan(
            queue: queue, assets: ["A": clip("IMG_0001")], folderFiles: [folderFile("f-other", "x.jpg")]
        )
        XCTAssertTrue(plan.enqueue.isEmpty)
        XCTAssertEqual(plan.notInBackupFolder, 1)
    }

    func testFindsALegacyStillWithNoFileIDByName() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: nil)
        queue.markCompleted(id: "B", fileID: nil)
        let plan = LivePhotoMotionBackfillPlanner.plan(
            queue: queue, assets: ["A": clip("IMG_0001"), "B": clip("IMG_0002")],
            folderFiles: [folderFile("f-A", "img_0001.heic")]
        )
        XCTAssertEqual(plan.enqueue.map(\.entryID), ["A#motion"])
        XCTAssertEqual(plan.notInBackupFolder, 1)
    }

    func testRecordsAClipAlreadyInTheFolderInsteadOfUploadingIt() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A")
        let plan = LivePhotoMotionBackfillPlanner.plan(
            queue: queue, assets: ["A": clip("IMG_0001")],
            folderFiles: [folderFile("f-A", "IMG_0001.HEIC"), folderFile("f-clip", "img_0001.mov")]
        )
        XCTAssertTrue(plan.enqueue.isEmpty)
        XCTAssertEqual(plan.existingClips, ["A#motion": "f-clip"])
        XCTAssertEqual(plan.report.alreadyHadMotion, 1)
    }

    func testCountsUploadedStillsNoLongerOnTheDevice() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "gone", fileID: "f-1")
        queue.enqueue(id: "gone-too", creationDate: Date())
        let plan = LivePhotoMotionBackfillPlanner.plan(queue: queue, assets: [:], folderFiles: [])
        XCTAssertEqual(plan.notOnDevice, 1, "only an uploaded still is worth reporting")
    }

    func testSkipsPlainPhotosAndPhotosThatAlreadyHaveMotion() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "plain", fileID: "f-1")
        queue.markCompleted(id: "A", fileID: "f-A")
        queue.markCompleted(id: "A#motion", fileID: "f-A-clip")
        queue.markCompleted(id: "B", fileID: "f-B")
        queue.enqueue(id: "B#motion", creationDate: Date())

        XCTAssertEqual(LivePhotoMotionBackfillPlanner.candidateIdentifiers(in: queue), ["plain"])
        let plan = LivePhotoMotionBackfillPlanner.plan(
            queue: queue, assets: ["plain": .notLive], folderFiles: [folderFile("f-1", "IMG.jpg")]
        )
        let report = plan.report
        XCTAssertEqual([report.queued, report.alreadyHadMotion, report.notInBackupFolder, report.notOnDevice],
                       [0, 0, 0, 0])
    }

    func testAStillNotUploadedYetIsNotCheckedAgainstTheFolder() {
        var queue = PhotoSyncQueue()
        queue.enqueue(id: "A", creationDate: Date())
        let plan = LivePhotoMotionBackfillPlanner.plan(queue: queue, assets: ["A": clip("IMG_0001")],
                                                       folderFiles: [])
        XCTAssertEqual(plan.enqueue.map(\.entryID), ["A#motion"])
    }

    func testWithNoFolderNothingCountsAsRemoved() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A")
        let plan = LivePhotoMotionBackfillPlanner.plan(queue: queue, assets: ["A": clip("IMG_0001")],
                                                       folderFiles: nil)
        XCTAssertEqual(plan.enqueue.map(\.entryID), ["A#motion"])
        XCTAssertEqual(plan.notInBackupFolder, 0)
    }
}

// MARK: - Service

@MainActor
final class LivePhotoMotionServiceTests: XCTestCase {

    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "LivePhotoMotionServiceTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSUT(exporter: PhotoAssetExporting = MotionExporter())
    -> (PhotoSyncService, UserDefaults, [PhotoUploadRequest]) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: PhotoSyncService.Keys.enabled)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        let store = PhotoSyncQueueStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json"))
        let sut = PhotoSyncService(defaults: defaults, queueStore: store, assetExporter: exporter)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.folderResolver = { _, _ in "folder-1" }
        return (sut, defaults, [])
    }

    /// Records each prepared request and answers with a file named after its upload id.
    private func recordUploads(on sut: PhotoSyncService) -> () -> [PhotoUploadRequest] {
        var requests: [PhotoUploadRequest] = []
        sut.uploadPreparer = { request in
            requests.append(request)
            return {
                UploadResult(id: "file-" + request.uploadID, name: request.export.fileName,
                             folderId: request.parentFolderID, sizeBytes: 1,
                             mimeType: request.export.mimeType, updatedAt: Date(),
                             importSource: request.importMetadata.importSource)
            }
        }
        return { requests }
    }

    func testKeepingMotionIsOnByDefault() {
        let (sut, _, _) = makeSUT()
        XCTAssertTrue(sut.keepLivePhotoMotion)
    }

    func testANewLivePhotoUploadsItsStillAndThenItsClip() async {
        let (sut, _, _) = makeSUT()
        let requests = recordUploads(on: sut)

        sut.enqueueIfNeeded([LiveAsset(localIdentifier: "A", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)
        await sut.debugSettle()

        let sent = requests()
        XCTAssertEqual(sent.map(\.uploadID), ["photo-sync:A", "photo-sync:A#motion"])
        XCTAssertEqual(sent.map(\.export.fileName), ["IMG_0001.HEIC", "IMG_0001.MOV"])
        XCTAssertEqual(sent[1].importMetadata.importSource, "photo-sync:A#motion")
        XCTAssertEqual(sent[1].importMetadata.createdAt, sent[0].importMetadata.createdAt,
                       "the clip carries the photo's capture date")
        XCTAssertEqual(sent[1].export.thumbnailBase64, "POSTER")
        XCTAssertEqual(sut.debugCompletedFileID("A#motion"), "file-photo-sync:A#motion")
        XCTAssertEqual(sut.pendingCount, 0)
    }

    func testMotionWithNoClipIsDroppedNotFailed() async {
        let exporter = MotionExporter()
        exporter.withoutClip = ["A"]
        let (sut, _, _) = makeSUT(exporter: exporter)
        _ = recordUploads(on: sut)

        sut.enqueueIfNeeded([LiveAsset(localIdentifier: "A", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)
        await sut.debugSettle()

        XCTAssertTrue(sut.debugIsCompleted("A"))
        XCTAssertFalse(sut.debugIsCompleted("A#motion"))
        XCTAssertNil(sut.debugFailedEntry("A#motion"))
        XCTAssertEqual(sut.pendingCount, 0)
        XCTAssertEqual(sut.failedCount, 0)
    }

    func testTurningMotionOffDropsWaitingClipsAndStopsQueueingThem() async {
        let (sut, _, _) = makeSUT()
        sut.hasAccessTokenProvider = { false }   // keep everything queued
        sut.enqueueIfNeeded([LiveAsset(localIdentifier: "A", creationDate: Date())])
        XCTAssertEqual(sut.pendingCount, 2)

        sut.keepLivePhotoMotion = false

        XCTAssertEqual(sut.pendingCount, 1)
        XCTAssertNil(sut.debugPendingEntry("A#motion"))
        sut.enqueueIfNeeded([LiveAsset(localIdentifier: "B", creationDate: Date())])
        XCTAssertNil(sut.debugPendingEntry("B#motion"))
    }

    func testBackfillChecksThenQueuesOnlyAfterConfirmation() async {
        let (sut, defaults, _) = makeSUT()
        let requests = recordUploads(on: sut)
        defaults.set("folder-1", forKey: PhotoSyncService.Keys.folderID)
        sut.debugMarkCompleted("A", fileID: "f-A")
        sut.debugMarkCompleted("B", fileID: "f-B")
        sut.debugMarkCompleted("gone", fileID: "f-gone")
        sut.motionAssetProvider = FakeMotionAssets(assets: [
            "A": clip("IMG_0001", bytes: 1_000_000),
            "B": clip("IMG_0002"),
        ])
        sut.folderPageLister = { _, _, offset in
            offset > 0 ? [] : [folderFile("f-A", "IMG_0001.HEIC"), folderFile("f-B", "IMG_0002.HEIC"),
                               folderFile("f-B-clip", "IMG_0002.MOV")]
        }

        await sut.checkLivePhotoMotionBackfill()

        XCTAssertEqual(sut.motionBackfillState, .awaitingConfirmation(count: 1, estimatedBytes: 1_000_000))
        XCTAssertNil(sut.debugPendingEntry("A#motion"), "nothing is queued before the user confirms")

        await sut.confirmLivePhotoMotionBackfill()
        await sut.debugSettle()

        XCTAssertEqual(requests().map(\.uploadID), ["photo-sync:A#motion"])
        XCTAssertEqual(sut.debugCompletedFileID("B#motion"), "f-B-clip", "an existing clip is recorded, not re-sent")
        guard case .finished(let report) = sut.motionBackfillState else {
            return XCTFail("expected a finished pass, got \(sut.motionBackfillState)")
        }
        XCTAssertEqual(report.queued, 1)
        XCTAssertEqual(report.alreadyHadMotion, 1)
        XCTAssertEqual(report.notOnDevice, 1)
        XCTAssertEqual(sut.lastMotionBackfill?.queued, 1)
    }

    func testASecondBackfillFindsNothingToDo() async {
        let (sut, defaults, _) = makeSUT()
        _ = recordUploads(on: sut)
        defaults.set("folder-1", forKey: PhotoSyncService.Keys.folderID)
        sut.debugMarkCompleted("A", fileID: "f-A")
        sut.motionAssetProvider = FakeMotionAssets(assets: ["A": clip("IMG_0001")])
        sut.folderPageLister = { _, _, _ in [folderFile("f-A", "IMG_0001.HEIC")] }

        await sut.checkLivePhotoMotionBackfill()
        await sut.confirmLivePhotoMotionBackfill()
        await sut.debugSettle()
        await sut.checkLivePhotoMotionBackfill()

        guard case .finished(let report) = sut.motionBackfillState else {
            return XCTFail("a pass with nothing to queue finishes without asking, got \(sut.motionBackfillState)")
        }
        XCTAssertEqual(report.queued, 0)
    }

    func testCancellingTheBackfillQueuesNothing() async {
        let (sut, defaults, _) = makeSUT()
        defaults.set("folder-1", forKey: PhotoSyncService.Keys.folderID)
        sut.debugMarkCompleted("A", fileID: "f-A")
        sut.motionAssetProvider = FakeMotionAssets(assets: ["A": clip("IMG_0001")])
        sut.folderPageLister = { _, _, _ in [folderFile("f-A", "IMG_0001.HEIC")] }

        await sut.checkLivePhotoMotionBackfill()
        sut.cancelLivePhotoMotionBackfill()
        await sut.confirmLivePhotoMotionBackfill()   // a stale confirm after cancel does nothing

        XCTAssertEqual(sut.motionBackfillState, .idle)
        XCTAssertNil(sut.debugPendingEntry("A#motion"))
    }

    func testTheBackfillNeedsMotionTurnedOn() async {
        let (sut, _, _) = makeSUT()
        sut.keepLivePhotoMotion = false
        await sut.checkLivePhotoMotionBackfill()
        guard case .failed = sut.motionBackfillState else {
            return XCTFail("expected a refusal, got \(sut.motionBackfillState)")
        }
    }
}

// MARK: - Upload sheet

final class PickedMediaLoaderMotionTests: XCTestCase {

    private struct Item: PickedItem {
        var assetIdentifier: String? = "A"
        var suggestedName: String? = "IMG_0001"
        var registeredTypeIdentifiers = ["public.heic"]
        func loadFile(forTypeIdentifier typeIdentifier: String) async throws -> URL {
            throw PickedMediaError.unsupportedItem
        }
    }

    private func loader(exporter: MotionExporter, keepsMotion: Bool) -> PickedMediaLoader {
        var loader = PickedMediaLoader()
        loader.exporter = exporter
        loader.canReadLibrary = { true }
        loader.assetDates = { _ in (Date(timeIntervalSince1970: 100), nil) }
        loader.keepsLivePhotoMotion = { keepsMotion }
        return loader
    }

    func testALivePhotoPickUploadsItsMotionToo() async throws {
        let files = try await loader(exporter: MotionExporter(), keepsMotion: true).load(Item())
        XCTAssertEqual(files.map(\.fileName), ["IMG_0001.HEIC", "IMG_0001.MOV"])
        XCTAssertEqual(files[1].importMetadata?.importSource, "photo-upload:A#motion")
        XCTAssertEqual(files[1].importMetadata?.createdAt, Date(timeIntervalSince1970: 100))
    }

    func testNoMotionWhenTheSettingIsOff() async throws {
        let exporter = MotionExporter()
        let files = try await loader(exporter: exporter, keepsMotion: false).load(Item())
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(exporter.clipCalls.isEmpty)
    }

    func testAPhotoWithNoClipIsJustThePhoto() async throws {
        let exporter = MotionExporter()
        exporter.withoutClip = ["A"]
        let files = try await loader(exporter: exporter, keepsMotion: true).load(Item())
        XCTAssertEqual(files.count, 1)
    }
}
