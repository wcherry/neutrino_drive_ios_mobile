import XCTest
import Photos
@testable import NeutrinoDrive

// MARK: - Fakes

/// Stands in for PhotoKit. The real provider reads `PHAssetResource.originalFilename`, which
/// a test target cannot produce.
private struct FakeAssetMetadataProvider: PhotoAssetMetadataProviding {
    var assets: [PhotoAssetMetadata] = []
    func metadata(forIdentifiers identifiers: [String]) -> [PhotoAssetMetadata] {
        assets.filter { identifiers.contains($0.localIdentifier) }
    }
}

private func asset(_ identifier: String, _ name: String,
                   created: Date, modified: Date? = nil) -> PhotoAssetMetadata {
    PhotoAssetMetadata(localIdentifier: identifier, originalFilename: name,
                       creationDate: created, modificationDate: modified)
}

private func file(_ id: String, _ name: String, createdAt: Date?) -> DriveFolderFile {
    DriveFolderFile(id: id, name: name, createdAt: createdAt)
}

private let captureDate = Date(timeIntervalSince1970: 1_562_198_400)   // 2019-07-04
private let uploadDate  = Date(timeIntervalSince1970: 1_758_412_800)   // 2025-09-21

// MARK: - PhotoDateRepairPlannerTests

/// The matching rules, in isolation. Getting these wrong is silent: a mismatched pair writes a
/// *different* wrong date over a wrong date, and afterwards nothing distinguishes the two.
final class PhotoDateRepairPlannerTests: XCTestCase {

    func test_plan_patchesAFileWhoseDateDoesNotMatchItsAsset() {
        let plan = PhotoDateRepairPlanner.plan(
            files: [file("file-1", "IMG_0001.HEIC", createdAt: uploadDate)],
            assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate)]
        )

        XCTAssertEqual(plan.patches.count, 1)
        XCTAssertEqual(plan.patches.first?.fileID, "file-1")
        XCTAssertEqual(plan.patches.first?.metadata.createdAt, captureDate)
    }

    func test_plan_carriesTheAssetIdentifierAsTheImportSource() {
        let plan = PhotoDateRepairPlanner.plan(
            files: [file("file-1", "IMG_0001.HEIC", createdAt: uploadDate)],
            assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate)]
        )

        XCTAssertEqual(plan.patches.first?.metadata.importSource, "photo-sync:asset-1")
    }

    func test_plan_usesTheAssetsModificationDate_whenItHasOne() {
        let edited = captureDate.addingTimeInterval(86_400)
        let plan = PhotoDateRepairPlanner.plan(
            files: [file("file-1", "IMG_0001.HEIC", createdAt: uploadDate)],
            assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate, modified: edited)]
        )

        XCTAssertEqual(plan.patches.first?.metadata.updatedAt, edited)
    }

    func test_plan_fallsBackToTheCaptureDate_whenTheAssetHasNoModificationDate() {
        let plan = PhotoDateRepairPlanner.plan(
            files: [file("file-1", "IMG_0001.HEIC", createdAt: uploadDate)],
            assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate)]
        )

        XCTAssertEqual(plan.patches.first?.metadata.updatedAt, captureDate)
    }

    /// The idempotency test. This is what lets a suspended pass be resumed by simply running
    /// it again, and what makes a second run cost nothing but the listing.
    func test_plan_skipsAFileWhoseDateAlreadyMatches() {
        let plan = PhotoDateRepairPlanner.plan(
            files: [file("file-1", "IMG_0001.HEIC", createdAt: captureDate)],
            assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate)]
        )

        XCTAssertTrue(plan.patches.isEmpty)
        XCTAssertEqual(plan.alreadyCorrect, 1)
    }

    /// The patch sends whole seconds while `PHAsset.creationDate` carries sub-second
    /// precision, so a correctly repaired file never reads back exactly equal. Without the
    /// tolerance every pass would re-patch every file it had already fixed.
    func test_plan_treatsASubSecondDifferenceAsAlreadyCorrect() {
        let plan = PhotoDateRepairPlanner.plan(
            files: [file("file-1", "IMG_0001.HEIC", createdAt: captureDate)],
            assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate.addingTimeInterval(0.6))]
        )

        XCTAssertEqual(plan.alreadyCorrect, 1)
    }

    func test_plan_countsAFilenameClaimedByTwoAssetsAsAmbiguous_andPatchesNothing() {
        let plan = PhotoDateRepairPlanner.plan(
            files: [file("file-1", "IMG_0001.HEIC", createdAt: uploadDate)],
            assets: [
                asset("asset-1", "IMG_0001.HEIC", created: captureDate),
                asset("asset-2", "IMG_0001.HEIC", created: captureDate.addingTimeInterval(99)),
            ]
        )

        XCTAssertTrue(plan.patches.isEmpty, "Guessing writes a wrong date over a wrong date")
        XCTAssertEqual(plan.ambiguous, 1)
    }

    func test_plan_countsAFileWithNoMatchingAssetAsNotOnDevice() {
        let plan = PhotoDateRepairPlanner.plan(
            files: [file("file-1", "IMG_9999.HEIC", createdAt: uploadDate)],
            assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate)]
        )

        XCTAssertEqual(plan.notOnDevice, 1)
        XCTAssertTrue(plan.patches.isEmpty)
    }

    /// A file the listing gave no creation date for cannot be shown to be correct, so it is
    /// patched rather than assumed fine — the patch is idempotent, the assumption is not.
    func test_plan_patchesAFileWithNoCreatedAt() {
        let plan = PhotoDateRepairPlanner.plan(
            files: [file("file-1", "IMG_0001.HEIC", createdAt: nil)],
            assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate)]
        )

        XCTAssertEqual(plan.patches.count, 1)
    }

    func test_plan_everyFileLandsInExactlyOneBucket() {
        let plan = PhotoDateRepairPlanner.plan(
            files: [
                file("f1", "IMG_0001.HEIC", createdAt: uploadDate),    // patch
                file("f2", "IMG_0002.HEIC", createdAt: captureDate),   // already correct
                file("f3", "IMG_0003.HEIC", createdAt: uploadDate),    // ambiguous
                file("f4", "notes.txt",     createdAt: uploadDate),    // not on device
            ],
            assets: [
                asset("a1", "IMG_0001.HEIC", created: captureDate),
                asset("a2", "IMG_0002.HEIC", created: captureDate),
                asset("a3", "IMG_0003.HEIC", created: captureDate),
                asset("a4", "IMG_0003.HEIC", created: captureDate),
            ]
        )

        XCTAssertEqual(plan.patches.count + plan.alreadyCorrect + plan.ambiguous + plan.notOnDevice, 4)
        XCTAssertEqual(plan.patches.map(\.fileID), ["f1"])
        XCTAssertEqual(plan.alreadyCorrect, 1)
        XCTAssertEqual(plan.ambiguous, 1)
        XCTAssertEqual(plan.notOnDevice, 1)
    }
}

// MARK: - PhotoDateRepairPassTests

/// The pass itself, over fakes: paging, the report, and the guards.
@MainActor
final class PhotoDateRepairPassTests: XCTestCase {

    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "PhotoDateRepairPassTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A service with a resolved destination folder, satisfied constraints, and a ledger that
    /// already knows about `identifiers`.
    private func makeSUT(identifiers: [String] = ["asset-1"],
                         assets: [PhotoAssetMetadata] = []) -> (PhotoSyncService, UserDefaults) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: PhotoSyncService.Keys.enabled)
        defaults.set("photos-folder", forKey: PhotoSyncService.Keys.folderID)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let sut = PhotoSyncService(defaults: defaults,
                                   queueStore: PhotoSyncQueueStore(fileURL: storeURL),
                                   assetExporter: FakeExporter())
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.assetMetadataProvider = FakeAssetMetadataProvider(assets: assets)
        // Wired by default so a guard test asserts the guard it means to: the "not ready yet"
        // check for unwired seams runs before the constraint checks.
        sut.folderPageLister = { _, _, _ in [] }
        sut.importMetadataStamper = { _, _ in }
        for identifier in identifiers {
            sut.debugMarkCompleted(identifier, fileID: nil)
        }
        return (sut, defaults)
    }

    private struct FakeExporter: PhotoAssetExporting {
        func exportData(for identifier: String, includeVideos: Bool,
                        networkAccessAllowed: Bool) async throws -> PhotoExport {
            PhotoExport(data: Data(), fileName: identifier, mimeType: "image/jpeg")
        }
    }

    // MARK: - Happy path

    func test_repair_patchesTheFilesWhoseDatesAreWrong() async {
        let (sut, _) = makeSUT(assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate)])
        sut.folderPageLister = { _, _, offset in
            offset == 0 ? [file("file-1", "IMG_0001.HEIC", createdAt: uploadDate)] : []
        }
        var patched: [String: DriveImportMetadata] = [:]
        sut.importMetadataStamper = { fileID, metadata in patched[fileID] = metadata }

        await sut.repairPhotoDates()

        XCTAssertEqual(patched["file-1"]?.createdAt, captureDate)
        guard case .finished(let report) = sut.dateRepairState else {
            return XCTFail("Expected .finished, got \(sut.dateRepairState)")
        }
        XCTAssertEqual(report.repaired, 1)
        XCTAssertEqual(report.examined, 1)
    }

    func test_repair_pagesUntilTheServerRunsOut() async {
        let names = (0..<250).map { String(format: "IMG_%04d.HEIC", $0) }
        let (sut, _) = makeSUT(
            identifiers: names.map { "asset-\($0)" },
            assets: names.map { asset("asset-\($0)", $0, created: captureDate) }
        )
        var requestedOffsets: [Int] = []
        sut.folderPageLister = { _, limit, offset in
            requestedOffsets.append(offset)
            let page = names.dropFirst(offset).prefix(limit)
            return page.enumerated().map { file("file-\($0.element)", $0.element, createdAt: uploadDate) }
        }
        var patchCount = 0
        sut.importMetadataStamper = { _, _ in patchCount += 1 }

        await sut.repairPhotoDates()

        XCTAssertEqual(requestedOffsets, [0, 200])
        XCTAssertEqual(patchCount, 250)
    }

    func test_repair_reportsEveryBucket() async {
        let (sut, _) = makeSUT(
            identifiers: ["a1", "a2", "a3", "a4"],
            assets: [
                asset("a1", "IMG_0001.HEIC", created: captureDate),
                asset("a2", "IMG_0002.HEIC", created: captureDate),
                asset("a3", "IMG_0003.HEIC", created: captureDate),
                asset("a4", "IMG_0003.HEIC", created: captureDate),
            ]
        )
        sut.folderPageLister = { _, _, offset in
            guard offset == 0 else { return [] }
            return [
                file("f1", "IMG_0001.HEIC", createdAt: uploadDate),
                file("f2", "IMG_0002.HEIC", createdAt: captureDate),
                file("f3", "IMG_0003.HEIC", createdAt: uploadDate),
                file("f4", "notes.txt", createdAt: uploadDate),
            ]
        }
        sut.importMetadataStamper = { _, _ in }

        await sut.repairPhotoDates()

        guard case .finished(let report) = sut.dateRepairState else {
            return XCTFail("Expected .finished, got \(sut.dateRepairState)")
        }
        XCTAssertEqual(report.repaired, 1)
        XCTAssertEqual(report.alreadyCorrect, 1)
        XCTAssertEqual(report.ambiguous, 1)
        XCTAssertEqual(report.notOnDevice, 1)
        XCTAssertEqual(report.failed, 0)
    }

    /// Run twice, and the second pass finds nothing left to do. This is the whole resumption
    /// strategy: there is no cursor to persist because restarting is free.
    func test_repair_runTwice_patchesNothingTheSecondTime() async {
        let (sut, _) = makeSUT(assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate)])
        var storedDate = uploadDate
        sut.folderPageLister = { _, _, offset in
            offset == 0 ? [file("file-1", "IMG_0001.HEIC", createdAt: storedDate)] : []
        }
        var patchCount = 0
        sut.importMetadataStamper = { _, metadata in
            patchCount += 1
            storedDate = metadata.createdAt
        }

        await sut.repairPhotoDates()
        await sut.repairPhotoDates()

        XCTAssertEqual(patchCount, 1)
        guard case .finished(let report) = sut.dateRepairState else {
            return XCTFail("Expected .finished, got \(sut.dateRepairState)")
        }
        XCTAssertEqual(report.alreadyCorrect, 1)
        XCTAssertEqual(report.repaired, 0)
    }

    func test_repair_persistsTheReportSoSettingsCanShowItAfterARelaunch() async {
        let (sut, _) = makeSUT(assets: [asset("asset-1", "IMG_0001.HEIC", created: captureDate)])
        sut.folderPageLister = { _, _, offset in
            offset == 0 ? [file("file-1", "IMG_0001.HEIC", createdAt: uploadDate)] : []
        }
        sut.importMetadataStamper = { _, _ in }

        await sut.repairPhotoDates()

        XCTAssertEqual(sut.lastDateRepair?.repaired, 1)
    }

    // MARK: - Failures

    func test_repair_countsAPermanentlyRejectedPatchAsFailed_andKeepsGoing() async {
        let (sut, _) = makeSUT(
            identifiers: ["a1", "a2"],
            assets: [
                asset("a1", "IMG_0001.HEIC", created: captureDate),
                asset("a2", "IMG_0002.HEIC", created: captureDate),
            ]
        )
        sut.folderPageLister = { _, _, offset in
            guard offset == 0 else { return [] }
            return [file("f1", "IMG_0001.HEIC", createdAt: uploadDate),
                    file("f2", "IMG_0002.HEIC", createdAt: uploadDate)]
        }
        sut.importMetadataStamper = { fileID, _ in
            if fileID == "f1" { throw DriveError.serverError(statusCode: 400) }
        }

        await sut.repairPhotoDates()

        guard case .finished(let report) = sut.dateRepairState else {
            return XCTFail("Expected .finished, got \(sut.dateRepairState)")
        }
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.repaired, 1, "One bad file must not abandon the rest of the folder")
    }

    func test_repair_failsTheWholePass_whenTheFolderCannotBeListed() async {
        let (sut, _) = makeSUT()
        sut.folderPageLister = { _, _, _ in throw DriveError.serverError(statusCode: 500) }

        await sut.repairPhotoDates()

        guard case .failed = sut.dateRepairState else {
            return XCTFail("Expected .failed, got \(sut.dateRepairState)")
        }
    }

    // MARK: - Guards

    func test_repair_refuses_whenNoBackupFolderHasBeenCreatedYet() async {
        let (sut, defaults) = makeSUT()
        defaults.removeObject(forKey: PhotoSyncService.Keys.folderID)
        sut.folderPageLister = { _, _, _ in XCTFail("must not list"); return [] }

        await sut.repairPhotoDates()

        XCTAssertEqual(sut.dateRepairState,
                       .failed("No photo backup folder has been created yet."))
    }

    func test_repair_refuses_whileWaitingForWiFi() async {
        let (sut, _) = makeSUT()
        sut.isOnWiFi = false
        sut.isNetworkExpensive = true
        sut.folderPageLister = { _, _, _ in XCTFail("must not list over cellular"); return [] }

        await sut.repairPhotoDates()

        XCTAssertEqual(sut.dateRepairState, .failed("Waiting for Wi-Fi."))
    }

    func test_repair_refuses_whenSignedOut() async {
        let (sut, _) = makeSUT()
        sut.hasAccessTokenProvider = { false }
        sut.folderPageLister = { _, _, _ in XCTFail("must not list"); return [] }

        await sut.repairPhotoDates()

        XCTAssertEqual(sut.dateRepairState, .failed("Sign in to repair photo dates."))
    }

    func test_repair_renewsTheAccessTokenFirst() async {
        let (sut, _) = makeSUT()
        var events: [String] = []
        sut.tokenRefresher = { events.append("refresh") }
        sut.folderPageLister = { _, _, _ in events.append("list"); return [] }
        sut.importMetadataStamper = { _, _ in }

        await sut.repairPhotoDates()

        XCTAssertEqual(events, ["refresh", "list"])
    }

    // MARK: - Report rendering

    func test_reportSummary_namesOnlyTheBucketsThatHappened() {
        var report = PhotoDateRepairReport()
        report.repaired = 12
        report.notOnDevice = 3

        XCTAssertEqual(report.summary, "12 repaired, 3 not on this device")
    }

    func test_reportSummary_alwaysNamesTheRepairedCount_evenAtZero() {
        XCTAssertEqual(PhotoDateRepairReport().summary, "0 repaired")
    }
}
