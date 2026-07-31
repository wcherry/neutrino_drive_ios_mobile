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
        var sut = PhotoSyncQueue(completed: ["asset-1"])
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
        sut.completed = ["completed-1", "completed-2"]
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

        sut.markCompleted(id: "asset-1")

        XCTAssertTrue(sut.pending.isEmpty)
        XCTAssertTrue(sut.completed.contains("asset-1"))
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
        var sut = PhotoSyncQueue(completed: ["still-exists", "deleted-from-library"])

        sut.compact(keepingIdentifiers: ["still-exists"])

        XCTAssertEqual(sut.completed, ["still-exists"])
    }
}
