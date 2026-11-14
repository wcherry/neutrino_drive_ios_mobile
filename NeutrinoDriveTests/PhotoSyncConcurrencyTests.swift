import XCTest
import Photos
@testable import NeutrinoDrive

private struct Asset: PhotoAssetProviding {
    let localIdentifier: String
    let creationDate: Date?
    var modificationDate: Date?
    var mediaType: PHAssetMediaType = .image
}

private struct InstantExporter: PhotoAssetExporting {
    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport {
        PhotoExport(data: Data("bytes".utf8), fileName: "\(identifier).jpg", mimeType: "image/jpeg")
    }
}

/// Counts how many prepares are running at once, and which ran alongside which.
@MainActor
private final class PrepareMeter {
    private(set) var running: Set<String> = []
    private(set) var peak = 0
    /// For each entry, the others running when it started.
    private(set) var companions: [String: Set<String>] = [:]

    func begin(_ id: String) {
        companions[id] = running
        for other in running { companions[other, default: []].insert(id) }
        running.insert(id)
        peak = max(peak, running.count)
    }

    func end(_ id: String) { running.remove(id) }
}

/// "photo-sync:A" → "A".
private func entryID(_ uploadID: String) -> String {
    String(uploadID.dropFirst("photo-sync:".count))
}

@MainActor
final class PhotoSyncConcurrencyTests: XCTestCase {

    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "PhotoSyncConcurrencyTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSUT(foreground: Bool, alone: Set<String> = []) -> (PhotoSyncService, PrepareMeter) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: PhotoSyncService.Keys.enabled)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        let store = PhotoSyncQueueStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json"))
        let sut = PhotoSyncService(defaults: defaults, queueStore: store, assetExporter: InstantExporter())
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.folderResolver = { _, _ in "folder-1" }
        sut.isForegroundProvider = { foreground }
        sut.needsPreparingAlone = { alone.contains($0) }
        let meter = PrepareMeter()
        sut.uploadPreparer = { request in
            let id = entryID(request.uploadID)
            meter.begin(id)
            try await Task.sleep(nanoseconds: 30_000_000)   // long enough for others to start
            meter.end(id)
            return {
                UploadResult(id: "file-\(id)", name: request.export.fileName, folderId: "folder-1",
                             sizeBytes: 1, mimeType: "image/jpeg", updatedAt: Date())
            }
        }
        return (sut, meter)
    }

    private func enqueue(_ ids: [String], on sut: PhotoSyncService) {
        let start = Date(timeIntervalSince1970: 1_000_000)
        sut.enqueueIfNeeded(ids.enumerated().map { index, id in
            Asset(localIdentifier: id, creationDate: start.addingTimeInterval(Double(index)))
        })
    }

    func testTheForegroundPreparesSeveralPhotosAtOnce() async {
        let (sut, meter) = makeSUT(foreground: true)
        enqueue(["A", "B", "C", "D", "E"], on: sut)

        _ = await sut.drain(ignoringPowerConstraint: false)
        await sut.debugSettle()

        XCTAssertEqual(meter.peak, 3)
        XCTAssertEqual(sut.pendingCount, 0)
        for id in ["A", "B", "C", "D", "E"] {
            XCTAssertEqual(sut.debugCompletedFileID(id), "file-\(id)", "each photo uploaded exactly once")
        }
    }

    func testTheLimitIsAdjustable() async {
        let (sut, meter) = makeSUT(foreground: true)
        sut.maxConcurrentPrepares = 2
        enqueue(["A", "B", "C", "D"], on: sut)
        _ = await sut.drain(ignoringPowerConstraint: false)
        await sut.debugSettle()
        XCTAssertEqual(meter.peak, 2)
    }

    func testInTheBackgroundPhotosArePreparedOneAtATime() async {
        let (sut, meter) = makeSUT(foreground: false)
        enqueue(["A", "B", "C"], on: sut)

        _ = await sut.drain(ignoringPowerConstraint: false)
        await sut.debugSettle()

        XCTAssertEqual(meter.peak, 1)
        XCTAssertEqual(sut.pendingCount, 0)
    }

    func testABackgroundTaskPreparesOneAtATimeEvenWhileFrontmost() async {
        let (sut, meter) = makeSUT(foreground: true)
        enqueue(["A", "B", "C"], on: sut)
        _ = await sut.drain(ignoringPowerConstraint: false, isBackgroundExpired: { false })
        await sut.debugSettle()
        XCTAssertEqual(meter.peak, 1)
    }

    func testALargeAssetIsPreparedAlone() async {
        let (sut, meter) = makeSUT(foreground: true, alone: ["V"])
        enqueue(["A", "B", "V", "C", "D"], on: sut)

        _ = await sut.drain(ignoringPowerConstraint: false)
        await sut.debugSettle()

        XCTAssertEqual(meter.companions["V"], [], "nothing runs alongside a video or RAW original")
        XCTAssertGreaterThan(meter.peak, 1, "the photos around it still overlap")
        XCTAssertEqual(sut.debugCompletedFileID("V"), "file-V")
        XCTAssertEqual(sut.pendingCount, 0)
    }

    func testTheTransferLimitStillHoldsWhilePreparingConcurrently() async {
        let (sut, _) = makeSUT(foreground: true)
        sut.maxTransfersInFlight = 2
        var peakInFlight = 0
        var inFlight = 0
        sut.uploadPreparer = { request in
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            return {
                try await Task.sleep(nanoseconds: 20_000_000)
                inFlight -= 1
                return UploadResult(id: "file-\(request.uploadID)", name: "x", folderId: nil,
                                    sizeBytes: 1, mimeType: "image/jpeg", updatedAt: Date())
            }
        }
        enqueue(["A", "B", "C", "D", "E"], on: sut)

        _ = await sut.drain(ignoringPowerConstraint: false)
        await sut.debugSettle()

        XCTAssertLessThanOrEqual(peakInFlight, 2)
        XCTAssertEqual(sut.pendingCount, 0)
    }

    // MARK: - Waiting on iOS

    func testHandedOffCountsLiveClaimsOnly() {
        var queue = PhotoSyncQueue()
        let now = Date()
        queue.enqueue(id: "A", creationDate: now)
        queue.enqueue(id: "B", creationDate: now)
        queue.enqueue(id: "C", creationDate: now)
        queue.markHandedOff(id: "A", to: .app, at: now)
        queue.markHandedOff(id: "B", to: .photosExtension, at: now.addingTimeInterval(-PhotoSyncQueue.handoffLease - 1))
        XCTAssertEqual(queue.handedOffCount(asOf: now), 1, "an expired claim isn't waiting on iOS any more")
    }
}
