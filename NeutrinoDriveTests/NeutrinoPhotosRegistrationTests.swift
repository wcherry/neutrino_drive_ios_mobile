import XCTest
import Photos
@testable import NeutrinoDrive

// MARK: - Fakes

/// The Photos API, in memory. Records every call; a file can be pre-registered (as the web does
/// lazily) or made to fail.
@MainActor
private final class FakeRegistrar: PhotoLibraryRegistering {
    struct Registration { let fileID: String; let captureDate: Date?; let metadata: [String: Any] }

    var registrations: [Registration] = []
    var replaced: [(id: String, metadata: [String: Any])] = []
    var fetched: [String] = []
    /// fileID → an existing record's metadata; registering it returns that, unchanged.
    var alreadyRegistered: [String: [String: Any]] = [:]
    /// Stored documents by photo id.
    var documents: [String: [String: Any]] = [:]
    var failing: [String: Error] = [:]

    func registerPhoto(fileID: String, captureDate: Date?, metadata: [String: Any]) async throws -> LibraryPhoto {
        if let error = failing[fileID] { throw error }
        registrations.append(Registration(fileID: fileID, captureDate: captureDate, metadata: metadata))
        let id = "photo-\(fileID)"
        let stored = alreadyRegistered[fileID] ?? metadata
        documents[id] = stored
        return LibraryPhoto(id: id, metadata: stored)
    }

    func libraryPhoto(id: String) async throws -> LibraryPhoto {
        fetched.append(id)
        return LibraryPhoto(id: id, metadata: documents[id])
    }

    func replacePhotoMetadata(id: String, metadata: [String: Any]) async throws {
        replaced.append((id, metadata))
        documents[id] = metadata
    }

    func registration(of fileID: String) -> Registration? {
        registrations.first { $0.fileID == fileID }
    }
}

private struct FakeFacts: PhotoAssetFactsProviding {
    var facts: [String: PhotoAssetFacts] = [:]
    var contentIdentifiers: [String: String] = [:]
    func facts(forAssetIdentifiers identifiers: [String]) -> [String: PhotoAssetFacts] {
        facts.filter { identifiers.contains($0.key) }
    }
    func contentIdentifier(forAssetIdentifier identifier: String) async -> String? {
        contentIdentifiers[identifier]
    }
}

private struct LivePhotoAsset: PhotoAssetProviding {
    let localIdentifier: String
    let creationDate: Date?
    var modificationDate: Date?
    var mediaType: PHAssetMediaType = .image
    var mediaSubtypes: PHAssetMediaSubtype = .photoLive
}

private final class StillAndClipExporter: PhotoAssetExporting {
    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport {
        PhotoExport(data: Data("still".utf8), fileName: "IMG_1.HEIC", mimeType: "image/heic")
    }
    func exportPairedVideo(for identifier: String, networkAccessAllowed: Bool) async throws -> PhotoExport {
        PhotoExport(data: Data("clip".utf8), fileName: "IMG_1.MOV", mimeType: "video/quicktime")
    }
}

private let captured = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
private let liveFacts = PhotoAssetFacts(creationDate: captured, isLivePhoto: true, isRAW: false,
                                        subtypes: ["hdr", "live"])

private func device(_ metadata: [String: Any]?) -> [String: Any]? { metadata?["device"] as? [String: Any] }
private func motion(_ metadata: [String: Any]?) -> [String: Any]? { metadata?["motionPhoto"] as? [String: Any] }

// MARK: - Metadata

final class PhotoLibraryMetadataTests: XCTestCase {

    func testDeviceFactsUseNeutrinoPhotosKeys() {
        let d = PhotoLibraryMetadata.device(localIdentifier: "A", isLivePhoto: true, isRAW: false,
                                            subtypes: ["live"], liveVideoFileID: "clip-1")
        XCTAssertEqual(Set(d.keys), ["localIdentifier", "isLivePhoto", "isRAW", "subtypes", "liveVideoFileID"])
        XCTAssertNil(PhotoLibraryMetadata.device(localIdentifier: "A", isLivePhoto: false, isRAW: false,
                                                 subtypes: [], liveVideoFileID: nil)["liveVideoFileID"])
    }

    func testMotionPhotoFollowsTheWebShape() {
        let withID = PhotoLibraryMetadata.motionPhoto(contentIdentifier: "CID")
        XCTAssertEqual(withID["subtype"] as? String, "live_photo_apple")
        XCTAssertEqual(withID["contentIdentifier"] as? String, "CID")
        XCTAssertNotNil(withID["signal"] as? String)
        XCTAssertNil(PhotoLibraryMetadata.motionPhoto(contentIdentifier: nil)["contentIdentifier"])
    }

    func testMergingKeepsEveryOtherKeyAndDeviceFact() {
        let existing: [String: Any] = ["width": 4032, "exif": ["make": "Apple"],
                                       "device": ["localIdentifier": "A", "isRAW": true]]
        let merged = PhotoLibraryMetadata.merged(existing, adding: [
            "device": ["liveVideoFileID": "clip-1"], "motionPhoto": ["subtype": "live_photo_apple"],
        ])
        XCTAssertEqual(merged["width"] as? Int, 4032)
        XCTAssertNotNil(merged["exif"])
        XCTAssertEqual(device(merged)?["isRAW"] as? Bool, true, "device facts already there survive")
        XCTAssertEqual(device(merged)?["liveVideoFileID"] as? String, "clip-1")
        XCTAssertNotNil(motion(merged))
    }

    func testContainsLooksInsideDevice() {
        let wanted: [String: Any] = ["device": ["localIdentifier": "A", "liveVideoFileID": "c"]]
        XCTAssertFalse(PhotoLibraryMetadata.contains(wanted, in: ["device": ["localIdentifier": "A"]]))
        XCTAssertTrue(PhotoLibraryMetadata.contains(wanted, in: ["device": ["localIdentifier": "A", "liveVideoFileID": "c"], "x": 1]))
        XCTAssertFalse(PhotoLibraryMetadata.contains(wanted, in: nil))
    }

    func testCaptureDateIsTheServersZonelessUTCShape() {
        XCTAssertEqual(PhotoLibraryMetadata.captureDateString(captured), "2023-11-14T22:13:20")
    }

    func testSubtypeNamesMatchNeutrinoPhotos() {
        XCTAssertEqual(PhotoLibraryMetadata.subtypeNames([.photoLive, .photoHDR, .photoScreenshot]),
                       ["hdr", "screenshot", "live"])
    }

    func testParsesARecord() throws {
        let photo = try LibraryPhoto(json: Data(#"{"id":"p1","fileId":"f1","metadata":{"device":{"localIdentifier":"A"}}}"#.utf8))
        XCTAssertEqual(photo.id, "p1")
        XCTAssertEqual(device(photo.metadata)?["localIdentifier"] as? String, "A")
        XCTAssertNil(try LibraryPhoto(json: Data(#"{"id":"p2","metadata":null}"#.utf8)).metadata)
    }
}

// MARK: - Ledger

final class PhotoRegistrationLedgerTests: XCTestCase {

    func testAnOldLedgerStillDecodes() throws {
        let json = #"{"pending":[],"failed":[],"completed":{"A":{"fileID":"f-A"}}}"#
        let queue = try JSONDecoder.photoSync.decode(PhotoSyncQueue.self, from: Data(json.utf8))
        XCTAssertEqual(queue.completedFileID(for: "A"), "f-A")
        XCTAssertFalse(queue.completed["A"]!.isAwaitingPhotoRegistration)
    }

    func testMarkingAndRegistering() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A", registerInPhotos: true)
        queue.markCompleted(id: "B", fileID: "f-B")
        XCTAssertTrue(queue.completed["A"]!.isAwaitingPhotoRegistration)
        XCTAssertFalse(queue.completed["B"]!.isAwaitingPhotoRegistration)

        queue.markRegistered(id: "A", photoID: "p-A")
        XCTAssertEqual(queue.completed["A"]?.photoID, "p-A")
        XCTAssertFalse(queue.completed["A"]!.isAwaitingPhotoRegistration)
    }

    func testMarkAllSkipsRegisteredAndUnlinkedFiles() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A")
        queue.markCompleted(id: "B", fileID: "f-B")
        queue.markRegistered(id: "B", photoID: "p-B")
        queue.markCompleted(id: "legacy", fileID: nil)
        XCTAssertEqual(queue.markAllAwaitingRegistration(), 1)
        XCTAssertEqual(queue.markAllAwaitingRegistration(), 0, "a second pass marks nothing")
        queue.clearAwaitingRegistrations()
        XCTAssertFalse(queue.completed["A"]!.isAwaitingPhotoRegistration)
    }
}

// MARK: - Planner

final class PhotoRegistrationPlannerTests: XCTestCase {

    func testAPlainPhotoIsRegisteredAlone() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A", registerInPhotos: true)
        let plan = PhotoRegistrationPlanner.plan(queue: queue)
        XCTAssertEqual(plan.jobs.count, 1)
        XCTAssertTrue(plan.jobs[0].registerStill)
        XCTAssertFalse(plan.jobs[0].registerClip)
        XCTAssertNil(plan.jobs[0].clipFileID)
    }

    func testALivePhotoWaitsForItsClip() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A", registerInPhotos: true)
        queue.enqueue(id: "A#motion", creationDate: Date())
        let plan = PhotoRegistrationPlanner.plan(queue: queue)
        XCTAssertTrue(plan.jobs.isEmpty)
        XCTAssertEqual(plan.waitingForMotion, 1)
    }

    func testAClipThatFailedDoesNotHoldItsStillBack() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A", registerInPhotos: true)
        queue.enqueue(id: "A#motion", creationDate: Date())
        queue.markFailed(id: "A#motion", error: "x", permanent: true)
        let plan = PhotoRegistrationPlanner.plan(queue: queue)
        XCTAssertEqual(plan.jobs.map(\.registerStill), [true])
    }

    func testThePairIsRegisteredTogether() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A", registerInPhotos: true)
        queue.markCompleted(id: "A#motion", fileID: "f-clip", registerInPhotos: true)
        let job = PhotoRegistrationPlanner.plan(queue: queue).jobs.first
        XCTAssertEqual(job?.registerStill, true)
        XCTAssertEqual(job?.registerClip, true)
        XCTAssertEqual(job?.clipFileID, "f-clip")
    }

    func testAClipAddedLaterLinksToItsRegisteredStill() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A")
        queue.markRegistered(id: "A", photoID: "p-A")
        queue.markCompleted(id: "A#motion", fileID: "f-clip", registerInPhotos: true)
        let job = PhotoRegistrationPlanner.plan(queue: queue).jobs.first
        XCTAssertEqual(job?.registerStill, false)
        XCTAssertEqual(job?.registerClip, true)
        XCTAssertEqual(job?.stillPhotoID, "p-A")
    }

    func testAClipWhoseStillIsNotInTheLibraryIsNotRegistered() {
        var queue = PhotoSyncQueue()
        queue.markCompleted(id: "A", fileID: "f-A")
        queue.markCompleted(id: "A#motion", fileID: "f-clip", registerInPhotos: true)
        let plan = PhotoRegistrationPlanner.plan(queue: queue)
        XCTAssertTrue(plan.jobs.isEmpty, "a clip on its own would show as a stray video")
        XCTAssertEqual(plan.unregistrable, ["A#motion"])
    }

    func testAnUploadWithNoFileIDCannotBeRegistered() {
        var queue = PhotoSyncQueue()
        queue.completed["A"] = .init(fileID: nil, awaitingPhotoRegistration: true)
        let plan = PhotoRegistrationPlanner.plan(queue: queue)
        XCTAssertTrue(plan.jobs.isEmpty)
        XCTAssertEqual(plan.unregistrable, ["A"])
    }
}

// MARK: - Service

@MainActor
final class NeutrinoPhotosRegistrationServiceTests: XCTestCase {

    private var suiteName = ""
    private var registrar: FakeRegistrar!

    override func setUp() {
        super.setUp()
        suiteName = "NeutrinoPhotosRegistrationServiceTests.\(UUID().uuidString)"
        registrar = FakeRegistrar()
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSUT(showInPhotos: Bool = true) -> PhotoSyncService {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: PhotoSyncService.Keys.enabled)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        let store = PhotoSyncQueueStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json"))
        let sut = PhotoSyncService(defaults: defaults, queueStore: store, assetExporter: StillAndClipExporter())
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.folderResolver = { _, _ in "folder-1" }
        sut.photoRegistrar = registrar
        sut.assetFactsProvider = FakeFacts(facts: ["A": liveFacts], contentIdentifiers: ["A": "CID-A"])
        sut.uploadPreparer = { request in
            {
                UploadResult(id: request.uploadID.hasSuffix("#motion") ? "f-clip" : "f-still",
                             name: request.export.fileName, folderId: "folder-1", sizeBytes: 1,
                             mimeType: request.export.mimeType, updatedAt: Date(),
                             importSource: request.importMetadata.importSource)
            }
        }
        sut.showInNeutrinoPhotos = showInPhotos
        return sut
    }

    func testOffByDefault() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let sut = PhotoSyncService(defaults: defaults, queueStore: PhotoSyncQueueStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
        XCTAssertFalse(sut.showInNeutrinoPhotos)
    }

    func testWhenOffNothingIsRegistered() async {
        let sut = makeSUT(showInPhotos: false)
        sut.enqueueIfNeeded([LivePhotoAsset(localIdentifier: "A", creationDate: captured)])
        _ = await sut.drain(ignoringPowerConstraint: false)
        await sut.debugSettle()
        _ = await sut.registerWaitingPhotos()
        XCTAssertTrue(registrar.registrations.isEmpty)
    }

    func testALivePhotoIsRegisteredClipFirstThenTheStillWithItsLink() async {
        let sut = makeSUT()
        sut.enqueueIfNeeded([LivePhotoAsset(localIdentifier: "A", creationDate: captured)])
        _ = await sut.drain(ignoringPowerConstraint: false)
        await sut.debugSettle()
        // Transfers land after the drain's own pass; the next drain takes them in.
        _ = await sut.registerWaitingPhotos()

        XCTAssertEqual(registrar.registrations.map(\.fileID), ["f-clip", "f-still"])
        let still = registrar.registration(of: "f-still")
        XCTAssertEqual(device(still?.metadata)?["liveVideoFileID"] as? String, "f-clip")
        XCTAssertEqual(device(still?.metadata)?["localIdentifier"] as? String, "A")
        XCTAssertEqual(device(still?.metadata)?["subtypes"] as? [String], ["hdr", "live"])
        XCTAssertEqual(motion(still?.metadata)?["contentIdentifier"] as? String, "CID-A")
        XCTAssertEqual(still?.captureDate, captured)
        let clip = registrar.registration(of: "f-clip")
        XCTAssertNil(device(clip?.metadata)?["liveVideoFileID"])
        XCTAssertEqual(motion(clip?.metadata)?["contentIdentifier"] as? String, "CID-A")
        XCTAssertTrue(registrar.replaced.isEmpty, "a fresh record needs no second write")
        XCTAssertEqual(sut.queueSnapshot.completed["A"]?.photoID, "photo-f-still")
        XCTAssertEqual(sut.queueSnapshot.completed["A#motion"]?.photoID, "photo-f-clip")

        let again = await sut.registerWaitingPhotos()
        XCTAssertEqual(again.registered, 0, "nothing is registered twice")
    }

    func testARecordTheWebAlreadyMadeGetsDrivesKeysMergedIn() async {
        let sut = makeSUT()
        registrar.alreadyRegistered["f-A"] = ["width": 4032]
        sut.debugMarkCompleted("A", fileID: "f-A")
        sut.mutateQueue { $0.completed["A"]?.awaitingPhotoRegistration = true }
        sut.assetFactsProvider = FakeFacts(facts: ["A": PhotoAssetFacts(creationDate: captured, isLivePhoto: false,
                                                                         isRAW: false, subtypes: [])])

        _ = await sut.registerWaitingPhotos()

        XCTAssertEqual(registrar.replaced.count, 1)
        let written = registrar.replaced[0].metadata
        XCTAssertEqual(written["width"] as? Int, 4032, "what the record had is kept")
        XCTAssertEqual(device(written)?["localIdentifier"] as? String, "A")
    }

    func testAClipAddedAfterItsStillIsMergedIntoTheStillsRecord() async {
        let sut = makeSUT()
        sut.debugMarkCompleted("A", fileID: "f-A")
        sut.mutateQueue { queue in
            queue.markRegistered(id: "A", photoID: "p-A")
            queue.markCompleted(id: "A#motion", fileID: "f-clip", registerInPhotos: true)
        }
        registrar.documents["p-A"] = ["device": ["localIdentifier": "A", "isRAW": false], "width": 10]

        _ = await sut.registerWaitingPhotos()

        XCTAssertEqual(registrar.registrations.map(\.fileID), ["f-clip"])
        XCTAssertEqual(registrar.fetched, ["p-A"])
        let written = registrar.documents["p-A"]
        XCTAssertEqual(written?["width"] as? Int, 10)
        XCTAssertEqual(device(written)?["liveVideoFileID"] as? String, "f-clip")
        XCTAssertEqual(motion(written)?["contentIdentifier"] as? String, "CID-A")
    }

    func testAFileGoneFromDriveStopsWaiting() async {
        let sut = makeSUT()
        sut.mutateQueue { $0.markCompleted(id: "A", fileID: "f-A", registerInPhotos: true) }
        registrar.failing["f-A"] = DriveError.serverError(statusCode: 404)

        let report = await sut.registerWaitingPhotos()

        XCTAssertEqual(report.failed, 0)
        XCTAssertFalse(sut.queueSnapshot.completed["A"]!.isAwaitingPhotoRegistration)
    }

    func testAFailureIsRetriedNextTime() async {
        let sut = makeSUT()
        sut.mutateQueue { $0.markCompleted(id: "A", fileID: "f-A", registerInPhotos: true) }
        registrar.failing["f-A"] = DriveError.serverError(statusCode: 503)

        let report = await sut.registerWaitingPhotos()
        XCTAssertEqual(report.failed, 1)
        XCTAssertTrue(sut.queueSnapshot.completed["A"]!.isAwaitingPhotoRegistration)

        registrar.failing = [:]
        let retry = await sut.registerWaitingPhotos()
        XCTAssertEqual(retry.registered, 1)
    }

    func testTurningItOffDropsWaitingRegistrations() {
        let sut = makeSUT()
        sut.mutateQueue { $0.markCompleted(id: "A", fileID: "f-A", registerInPhotos: true) }
        sut.showInNeutrinoPhotos = false
        XCTAssertFalse(sut.queueSnapshot.completed["A"]!.isAwaitingPhotoRegistration)
    }

    func testAddEarlierPhotosRegistersWhatWasBackedUpBefore() async {
        let sut = makeSUT()
        sut.debugMarkCompleted("A", fileID: "f-A")
        sut.debugMarkCompleted("B", fileID: "f-B")
        sut.debugMarkCompleted("legacy", fileID: nil)
        sut.assetFactsProvider = FakeFacts()

        await sut.addEarlierPhotosToNeutrinoPhotos()

        guard case .finished(let report) = sut.photosRegistrationState else {
            return XCTFail("expected a finished pass, got \(sut.photosRegistrationState)")
        }
        XCTAssertEqual(report.registered, 2)
        XCTAssertEqual(Set(registrar.registrations.map(\.fileID)), ["f-A", "f-B"])
        XCTAssertNil(registrar.registration(of: "f-A")?.captureDate, "no asset facts, no capture date")
        XCTAssertEqual(sut.lastPhotosRegistration?.registered, 2)

        await sut.addEarlierPhotosToNeutrinoPhotos()
        guard case .finished(let second) = sut.photosRegistrationState else { return XCTFail() }
        XCTAssertEqual(second.registered, 0)
    }

    func testAddEarlierPhotosNeedsTheSettingOn() async {
        let sut = makeSUT(showInPhotos: false)
        await sut.addEarlierPhotosToNeutrinoPhotos()
        guard case .failed = sut.photosRegistrationState else {
            return XCTFail("expected a refusal, got \(sut.photosRegistrationState)")
        }
    }
}

// MARK: - Photos extension

@MainActor
final class PhotoRegistrationExtensionTests: XCTestCase {

    func testTheExtensionMarksItsUploadsForTheAppToRegister() async {
        let suite = "PhotoRegistrationExtensionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(true, forKey: PhotoSyncKeys.enabled)
        defaults.set(anchor, forKey: PhotoSyncKeys.anchorDate)
        defaults.set("folder-1", forKey: PhotoSyncKeys.folderID)
        defaults.set(true, forKey: PhotoSyncKeys.showInNeutrinoPhotos)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PhotoSyncQueueStore(fileURL: directory.appendingPathComponent("queue.json"))

        let sut = PhotoUploadExtensionRunner(defaults: defaults, queueStore: store,
                                             assetExporter: StillAndClipExporter(),
                                             runLog: PhotoExtensionRunLog(fileURL: directory.appendingPathComponent("runs.json")))
        sut.isFeatureEnabled = { true }
        sut.hasFullLibraryAccess = { true }
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isUnpluggedProvider = { false }
        sut.isLowPowerModeEnabledProvider = { false }
        sut.assetsCreatedSince = { _ in
            [LivePhotoAsset(localIdentifier: "A", creationDate: anchor.addingTimeInterval(60), mediaSubtypes: [])]
        }
        sut.uploadPreparer = { _ in
            { UploadResult(id: "f-A", name: "IMG_1.HEIC", folderId: "folder-1", sizeBytes: 1,
                           mimeType: "image/heic", updatedAt: Date()) }
        }

        _ = await sut.run()
        await sut.debugSettle()

        XCTAssertTrue(store.load().completed["A"]!.isAwaitingPhotoRegistration)
    }
}
