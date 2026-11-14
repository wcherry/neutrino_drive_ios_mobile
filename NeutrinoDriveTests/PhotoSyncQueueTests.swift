import XCTest
@testable import NeutrinoDrive

/// Unit tests for `PhotoSyncQueue`'s dedupe, ordering, and retry-backoff logic, and for
/// `PhotoSyncQueueStore`'s JSON persistence.
final class PhotoSyncQueueTests: XCTestCase {

    // MARK: - Enqueue / Dedupe

    func test_enqueue_addsNewEntryToPending() {
        var sut = PhotoSyncQueue()
        let added = sut.enqueue(id: "asset-1", creationDate: Date())
        XCTAssertTrue(added)
        XCTAssertTrue(sut.pending.contains(where: { $0.id == "asset-1" }))
    }

    func test_enqueue_dedupesAgainstPending() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "asset-1", creationDate: Date())
        let addedAgain = sut.enqueue(id: "asset-1", creationDate: Date())

        XCTAssertFalse(addedAgain)
        XCTAssertEqual(sut.pending.count, 1)
    }

    func test_enqueue_dedupesAgainstCompleted() {
        var sut = PhotoSyncQueue(completed: ["asset-1": .init()])
        let added = sut.enqueue(id: "asset-1", creationDate: Date())

        XCTAssertFalse(added)
        XCTAssertTrue(sut.pending.isEmpty)
    }

    func test_enqueue_dedupesAgainstFailed() {
        let failedEntry = PhotoSyncQueue.Entry(id: "asset-1", creationDate: Date(), attempts: 5)
        var sut = PhotoSyncQueue(failed: [failedEntry])
        let added = sut.enqueue(id: "asset-1", creationDate: Date())

        XCTAssertFalse(added)
        XCTAssertTrue(sut.pending.isEmpty)
    }

    // MARK: - JSON round-trip

    func test_roundTrip_throughJSONEncodeDecode_preservesAllCollections() throws {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "pending-1", creationDate: Date(timeIntervalSince1970: 1000))
        sut.completed = ["completed-1": .init(fileID: "file-1"), "completed-2": .init()]
        sut.failed = [PhotoSyncQueue.Entry(id: "failed-1", creationDate: Date(timeIntervalSince1970: 2000),
                                           attempts: 5, lastError: "boom")]

        let data = try JSONEncoder().encode(sut)
        let decoded = try JSONDecoder().decode(PhotoSyncQueue.self, from: data)

        XCTAssertEqual(decoded.pending.map(\.id), sut.pending.map(\.id))
        XCTAssertEqual(decoded.completed, sut.completed)
        XCTAssertEqual(decoded.failed.map(\.id), sut.failed.map(\.id))
        XCTAssertEqual(decoded.failed.first?.attempts, 5)
        XCTAssertEqual(decoded.failed.first?.lastError, "boom")
    }

    func test_store_saveThenLoad_roundTripsQueue() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let store = PhotoSyncQueueStore(fileURL: tempURL)

        var queue = PhotoSyncQueue()
        queue.enqueue(id: "asset-1", creationDate: Date(timeIntervalSince1970: 500))
        store.save(queue)

        let loaded = store.load()
        XCTAssertEqual(loaded.pending.map(\.id), ["asset-1"])
    }

    func test_store_load_withNoFile_returnsEmptyQueue() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let store = PhotoSyncQueueStore(fileURL: tempURL)

        let loaded = store.load()
        XCTAssertTrue(loaded.pending.isEmpty)
        XCTAssertTrue(loaded.completed.isEmpty)
        XCTAssertTrue(loaded.failed.isEmpty)
    }

    // MARK: - Draining — oldest first

    func test_drainable_ordersByCreationDate_oldestFirst() {
        var sut = PhotoSyncQueue()
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        sut.enqueue(id: "newer", creationDate: newer)
        sut.enqueue(id: "older", creationDate: older)

        let drainable = sut.drainable()
        XCTAssertEqual(drainable.map(\.id), ["older", "newer"])
    }

    func test_drainable_sortsBacklogEntriesAfterNewOnes_stillOldestFirstWithinEachGroup() {
        var sut = PhotoSyncQueue()
        let boundary = Date(timeIntervalSince1970: 1000)
        sut.enqueue(id: "backlog-newer", creationDate: Date(timeIntervalSince1970: 900))
        sut.enqueue(id: "new-newer",     creationDate: Date(timeIntervalSince1970: 1200))
        sut.enqueue(id: "backlog-older", creationDate: Date(timeIntervalSince1970: 100))
        sut.enqueue(id: "new-older",     creationDate: Date(timeIntervalSince1970: 1100))

        let drainable = sut.drainable(newerThan: boundary)

        XCTAssertEqual(drainable.map(\.id), ["new-older", "new-newer", "backlog-older", "backlog-newer"])
    }

    func test_drainable_withoutABoundary_isPlainCaptureOrder() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "newer", creationDate: Date(timeIntervalSince1970: 200))
        sut.enqueue(id: "older", creationDate: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(sut.drainable().map(\.id), ["older", "newer"])
    }

    func test_drainable_excludesEntriesWithFutureNextAttemptAfter() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "asset-1", creationDate: Date())
        sut.markFailed(id: "asset-1", error: "network blip")   // schedules nextAttemptAfter 30s out

        XCTAssertTrue(sut.drainable(asOf: Date()).isEmpty)
        XCTAssertFalse(sut.drainable(asOf: Date().addingTimeInterval(31)).isEmpty)
    }

    // MARK: - Retry backoff schedule

    func test_markFailed_firstFailure_schedulesThirtySecondBackoff() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "asset-1", creationDate: Date())
        sut.markFailed(id: "asset-1", error: "timeout")

        let entry = sut.pending.first(where: { $0.id == "asset-1" })
        XCTAssertEqual(entry?.attempts, 1)
        let delay = entry?.nextAttemptAfter?.timeIntervalSinceNow ?? 0
        XCTAssertEqual(delay, 30, accuracy: 2)
    }

    func test_markFailed_advancesThroughFullBackoffSchedule() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "asset-1", creationDate: Date())

        let expectedDelays: [TimeInterval] = [30, 120, 600, 3600, 21600]
        for (index, expected) in expectedDelays.enumerated() {
            sut.markFailed(id: "asset-1", error: "attempt \(index + 1)")
            if index < expectedDelays.count - 1 {
                let entry = sut.pending.first(where: { $0.id == "asset-1" })
                XCTAssertEqual(entry?.attempts, index + 1)
                let delay = entry?.nextAttemptAfter?.timeIntervalSinceNow ?? 0
                XCTAssertEqual(delay, expected, accuracy: 2, "attempt \(index + 1)")
            }
        }
    }

    func test_markFailed_fifthFailure_movesToFailed() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "asset-1", creationDate: Date())

        for _ in 1...5 {
            sut.markFailed(id: "asset-1", error: "network error")
        }

        XCTAssertTrue(sut.pending.isEmpty)
        XCTAssertEqual(sut.failed.count, 1)
        XCTAssertEqual(sut.failed.first?.id, "asset-1")
        XCTAssertEqual(sut.failed.first?.attempts, 5)
    }

    func test_markFailed_beforeFifthFailure_staysInPending() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "asset-1", creationDate: Date())

        for _ in 1...4 {
            sut.markFailed(id: "asset-1", error: "network error")
        }

        XCTAssertEqual(sut.pending.count, 1)
        XCTAssertTrue(sut.failed.isEmpty)
    }

    // MARK: - Permanent failure (e.g. HTTP 403)

    func test_markFailed_permanent_shortCircuitsToFailedImmediately() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "asset-1", creationDate: Date())

        sut.markFailed(id: "asset-1", error: "403 Forbidden", permanent: true)

        XCTAssertTrue(sut.pending.isEmpty)
        XCTAssertEqual(sut.failed.count, 1)
        XCTAssertEqual(sut.failed.first?.attempts, 1)
        XCTAssertEqual(sut.failed.first?.lastError, "403 Forbidden")
    }

    // MARK: - Completion

    func test_markCompleted_movesEntryFromPendingToCompleted() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "asset-1", creationDate: Date())

        sut.markCompleted(id: "asset-1", fileID: "file-1")

        XCTAssertTrue(sut.pending.isEmpty)
        XCTAssertNotNil(sut.completed["asset-1"])
    }

    /// The whole point of the ledger change in issue #31: without the file id there is nothing
    /// to PATCH the capture date onto, and repairing history falls back to matching filenames.
    func test_markCompleted_recordsTheDriveFileTheAssetBecame() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "asset-1", creationDate: Date())

        sut.markCompleted(id: "asset-1", fileID: "file-77")

        XCTAssertEqual(sut.completedFileID(for: "asset-1"), "file-77")
    }

    func test_completedFileID_isNilForAnAssetThatHasNotCompleted() {
        var sut = PhotoSyncQueue()
        sut.enqueue(id: "asset-1", creationDate: Date())

        XCTAssertNil(sut.completedFileID(for: "asset-1"))
    }

    // MARK: - Retry Failed

    func test_retryAllFailed_movesEntriesBackToPendingWithResetState() {
        let failedEntry = PhotoSyncQueue.Entry(id: "asset-1", creationDate: Date(), attempts: 5,
                                               lastError: "gave up", nextAttemptAfter: nil)
        var sut = PhotoSyncQueue(failed: [failedEntry])

        sut.retryAllFailed()

        XCTAssertTrue(sut.failed.isEmpty)
        let entry = sut.pending.first(where: { $0.id == "asset-1" })
        XCTAssertEqual(entry?.attempts, 0)
        XCTAssertNil(entry?.lastError)
    }

    // MARK: - Compaction

    func test_compact_dropsCompletedIdentifiersNotInValidSet() {
        var sut = PhotoSyncQueue(completed: ["still-exists": .init(fileID: "file-1"),
                                             "deleted-from-library": .init(fileID: "file-2")])

        sut.compact(keepingIdentifiers: ["still-exists"])

        XCTAssertEqual(sut.completed, ["still-exists": .init(fileID: "file-1")])
    }

    // MARK: - Legacy ledger migration
    //
    // Before issue #31 `completed` was encoded as a bare array of identifiers. Failing to read
    // that form does not degrade gracefully: `PhotoSyncQueueStore.load` turns a decode error
    // into an *empty* queue, so the dedup ledger forgets every photo it ever uploaded and the
    // whole library re-uploads itself on the next scan.

    func test_decode_readsThePreIssue31SetForm_asCompletedEntriesWithNoFileID() throws {
        let legacy = Data("""
        {"pending":[],"completed":["asset-1","asset-2"],"failed":[]}
        """.utf8)

        let decoded = try JSONDecoder.photoSync.decode(PhotoSyncQueue.self, from: legacy)

        XCTAssertEqual(Set(decoded.completed.keys), ["asset-1", "asset-2"])
        XCTAssertNil(decoded.completedFileID(for: "asset-1"))
    }

    func test_decode_ofTheLegacyForm_stillDedupes() throws {
        let legacy = Data("""
        {"pending":[],"completed":["asset-1"],"failed":[]}
        """.utf8)

        var decoded = try JSONDecoder.photoSync.decode(PhotoSyncQueue.self, from: legacy)

        XCTAssertFalse(decoded.enqueue(id: "asset-1", creationDate: Date()),
                       "A migrated ledger that stops deduping re-uploads the entire library")
    }

    func test_store_load_ofALegacyQueueFile_keepsTheLedger() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Data("""
        {"pending":[],"completed":["asset-1","asset-2"],"failed":[]}
        """.utf8).write(to: tempURL)

        let loaded = PhotoSyncQueueStore(fileURL: tempURL).load()

        XCTAssertEqual(loaded.completed.count, 2)
    }

    /// The encoder is synthesised and always writes the new shape; only the decoder is
    /// bilingual. A migrated queue must therefore stay migrated once it is saved.
    func test_encode_alwaysWritesTheDictionaryForm() throws {
        var sut = PhotoSyncQueue()
        sut.markCompleted(id: "asset-1", fileID: "file-1")

        let json = String(decoding: try JSONEncoder.photoSync.encode(sut), as: UTF8.self)

        XCTAssertTrue(json.contains("\"fileID\":\"file-1\""), json)
    }

    // MARK: - Modification date

    func test_enqueue_carriesTheAssetsModificationDate() {
        var sut = PhotoSyncQueue()
        let edited = Date(timeIntervalSince1970: 9_000)
        sut.enqueue(id: "asset-1", creationDate: Date(timeIntervalSince1970: 1_000),
                    modificationDate: edited)

        XCTAssertEqual(sut.pending.first?.modificationDate, edited)
    }

    /// A queue file written before the field existed must still load — and its entries simply
    /// have no modification date, which the upload path reads as "same as the capture date".
    func test_decode_ofAnEntryWithoutAModificationDate_leavesItNil() throws {
        let legacy = Data("""
        {"pending":[{"id":"asset-1","creationDate":"1970-01-01T00:16:40Z","attempts":0}],
         "completed":{},"failed":[]}
        """.utf8)

        let decoded = try JSONDecoder.photoSync.decode(PhotoSyncQueue.self, from: legacy)

        XCTAssertEqual(decoded.pending.first?.id, "asset-1")
        XCTAssertNil(decoded.pending.first?.modificationDate)
    }
}
