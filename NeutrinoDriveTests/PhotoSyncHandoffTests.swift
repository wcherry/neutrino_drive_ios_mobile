import XCTest
import Photos
@testable import NeutrinoDrive

/// The pieces that let the app and the Photos extension drain one queue (#38, Phase 2): hand-off
/// claims, the store's locked read-modify-write and its move into the App Group, the move of the
/// settings into the shared suite, and when the extension is registered at all.
final class PhotoSyncHandoffTests: XCTestCase {

    private func scratchURL(_ name: String = UUID().uuidString + ".json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSyncHandoffTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    // MARK: - Claims

    func test_drainable_leavesOutAnEntryAnotherProcessClaimed() {
        var queue = PhotoSyncQueue()
        queue.enqueue(id: "asset-1", creationDate: Date())
        queue.markHandedOff(id: "asset-1", to: .photosExtension)

        XCTAssertTrue(queue.drainable(for: .app).isEmpty)
    }

    /// The owner can ask its own session whether the transfer is still there, so its own claim
    /// must not hide the entry from it — that is how it collects or retries after a relaunch.
    func test_drainable_keepsAnEntryTheAskingProcessClaimed() {
        var queue = PhotoSyncQueue()
        queue.enqueue(id: "asset-1", creationDate: Date())
        queue.markHandedOff(id: "asset-1", to: .photosExtension)

        XCTAssertEqual(queue.drainable(for: .photosExtension).map(\.id), ["asset-1"])
    }

    func test_drainable_returnsAnEntryOnceTheClaimHasLapsed() {
        var queue = PhotoSyncQueue()
        queue.enqueue(id: "asset-1", creationDate: Date())
        let claimedAt = Date()
        queue.markHandedOff(id: "asset-1", to: .photosExtension, at: claimedAt)

        let later = claimedAt.addingTimeInterval(PhotoSyncQueue.handoffLease + 1)
        XCTAssertEqual(queue.drainable(asOf: later, for: .app).map(\.id), ["asset-1"])
    }

    func test_markFailed_dropsTheClaim() {
        var queue = PhotoSyncQueue()
        queue.enqueue(id: "asset-1", creationDate: Date())
        queue.markHandedOff(id: "asset-1", to: .photosExtension)

        queue.markFailed(id: "asset-1", error: "boom")

        XCTAssertNil(queue.pending.first?.handoff)
    }

    func test_releaseHandoff_dropsTheClaim() {
        var queue = PhotoSyncQueue()
        queue.enqueue(id: "asset-1", creationDate: Date())
        queue.markHandedOff(id: "asset-1", to: .app)

        queue.releaseHandoff(id: "asset-1")

        XCTAssertNil(queue.pending.first?.handoff)
    }

    /// A queue file from before the extension has no `handoff` field at all.
    func test_decode_aQueueWrittenBeforeClaimsExisted() throws {
        let json = #"""
        {"pending":[{"id":"asset-1","creationDate":"2026-10-01T10:00:00Z","attempts":0}],
         "completed":{},"failed":[]}
        """#
        let queue = try JSONDecoder.photoSync.decode(PhotoSyncQueue.self, from: Data(json.utf8))

        XCTAssertEqual(queue.pending.map(\.id), ["asset-1"])
        XCTAssertNil(queue.pending.first?.handoff)
    }

    /// An owner this build has never heard of — from a later build — must not make the queue
    /// undecodable: an empty queue is an empty dedup ledger, and the library uploads again.
    func test_decode_anOwnerThisBuildDoesNotKnow() throws {
        let json = #"""
        {"pending":[{"id":"asset-1","creationDate":"2026-10-01T10:00:00Z","attempts":0,
                     "handoff":{"owner":"some-later-process","at":"2026-10-01T10:00:00Z"}}],
         "completed":{"asset-0":{"fileID":"file-0"}},"failed":[]}
        """#
        let queue = try JSONDecoder.photoSync.decode(PhotoSyncQueue.self, from: Data(json.utf8))

        XCTAssertEqual(queue.pending.first?.handoff?.owner.rawValue, "some-later-process")
        XCTAssertEqual(queue.completedFileID(for: "asset-0"), "file-0")
    }

    // MARK: - Store

    /// Two processes each holding a store on the same file: a change one makes must survive
    /// the other's next write. `save` of a whole in-memory copy is what used to lose it.
    func test_update_keepsAChangeAnotherStoreMadeToTheSameFile() {
        let url = scratchURL()
        let app = PhotoSyncQueueStore(fileURL: url)
        let photosExtension = PhotoSyncQueueStore(fileURL: url)

        app.update { $0.enqueue(id: "asset-1", creationDate: Date()) }
        photosExtension.update { $0.enqueue(id: "asset-2", creationDate: Date()) }
        app.update { $0.markCompleted(id: "asset-1", fileID: "file-1") }

        let queue = photosExtension.load()
        XCTAssertEqual(queue.pending.map(\.id), ["asset-2"])
        XCTAssertEqual(queue.completedFileID(for: "asset-1"), "file-1")
    }

    func test_update_returnsWhatTheBodyReturns() {
        let store = PhotoSyncQueueStore(fileURL: scratchURL())
        let added = store.update { $0.enqueue(id: "asset-1", creationDate: Date()) }
        XCTAssertTrue(added)
    }

    func test_load_movesAQueueLeftInTheLegacyLocation() throws {
        let legacy = scratchURL("legacy.json")
        let current = scratchURL("current.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        PhotoSyncQueueStore(fileURL: legacy).update {
            $0.markCompleted(id: "asset-1", fileID: "file-1")
        }

        let store = PhotoSyncQueueStore(fileURL: current, legacyFileURL: legacy)

        XCTAssertEqual(store.load().completedFileID(for: "asset-1"), "file-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "a copy left behind is a second ledger that drifts")
    }

    func test_load_neverOverwritesTheCurrentQueueWithTheLegacyOne() {
        let legacy = scratchURL("legacy.json")
        let current = scratchURL("current.json")
        PhotoSyncQueueStore(fileURL: legacy).update { $0.markCompleted(id: "old", fileID: "f-old") }
        PhotoSyncQueueStore(fileURL: current).update { $0.markCompleted(id: "new", fileID: "f-new") }

        let queue = PhotoSyncQueueStore(fileURL: current, legacyFileURL: legacy).load()

        XCTAssertEqual(queue.completedFileID(for: "new"), "f-new")
        XCTAssertNil(queue.completedFileID(for: "old"))
    }

    // MARK: - Settings

    func test_migrate_copiesSettingsIntoTheSharedSuiteOnce() {
        let old = UserDefaults(suiteName: "PhotoSyncHandoffTests.old.\(UUID().uuidString)")!
        let new = UserDefaults(suiteName: "PhotoSyncHandoffTests.new.\(UUID().uuidString)")!
        old.set(true, forKey: PhotoSyncKeys.enabled)
        old.set("folder-1", forKey: PhotoSyncKeys.folderID)
        new.set("folder-already-shared", forKey: PhotoSyncKeys.folderID)

        PhotoSyncDefaults.migrate(from: old, to: new)
        old.set(false, forKey: PhotoSyncKeys.wifiOnly)
        PhotoSyncDefaults.migrate(from: old, to: new)

        XCTAssertTrue(new.bool(forKey: PhotoSyncKeys.enabled))
        XCTAssertEqual(new.string(forKey: PhotoSyncKeys.folderID), "folder-already-shared")
        XCTAssertNil(new.object(forKey: PhotoSyncKeys.wifiOnly),
                     "copied once; the shared suite is the source of truth from then on")
        XCTAssertTrue(old.bool(forKey: PhotoSyncKeys.enabled), "kept for a downgrade")
    }

    // MARK: - Registration

    func test_shouldEnable_onlyWithFullAccess() {
        XCTAssertTrue(PhotoUploadExtensionRegistration.shouldEnable(
            featureEnabled: true, photoSyncEnabled: true, authorization: .authorized))
        XCTAssertFalse(PhotoUploadExtensionRegistration.shouldEnable(
            featureEnabled: true, photoSyncEnabled: true, authorization: .limited))
        XCTAssertFalse(PhotoUploadExtensionRegistration.shouldEnable(
            featureEnabled: true, photoSyncEnabled: false, authorization: .authorized))
        XCTAssertFalse(PhotoUploadExtensionRegistration.shouldEnable(
            featureEnabled: false, photoSyncEnabled: true, authorization: .authorized))
    }
}
