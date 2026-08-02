import XCTest
@testable import NeutrinoDrive

/// Tests for the local access signal and the caching policy behind Phase 5 "Smart Offline Sync".
///
/// The policy is a pure function (`SmartOfflineSyncService.makePlan`) precisely so it can be
/// tested here without a network, a filesystem, or a battery — it is the part that can quietly
/// fill a user's disk or delete the wrong file, so it is the part that most needs proving.
final class SmartOfflineSyncTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartoffline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func record(_ id: String,
                        count: Int,
                        daysAgo: Double,
                        size: Int64? = 10 * 1024 * 1024,
                        now: Date = Date()) -> FileAccessRecord {
        FileAccessRecord(id: id, name: "\(id).mp4", mimeType: "video/mp4", sizeBytes: size,
                         accessCount: count,
                         lastAccessed: now.addingTimeInterval(-daysAgo * 86_400))
    }

    private func offline(_ id: String, size: Int64, managed: Bool) -> OfflineFile {
        OfflineFile(id: id, name: "\(id).mp4", mimeType: "video/mp4", sizeBytes: size,
                    localURL: tempDir.appendingPathComponent(id), cachedAt: Date(),
                    isManaged: managed)
    }

    // MARK: - FileAccessTracker

    func test_tracker_recordsAndAccumulatesAccessCount() throws {
        try XCTSkipUnless(FeatureFlags.smartOfflineSync, "feature disabled")
        let tracker = FileAccessTracker(storageDirectory: tempDir)

        tracker.recordAccess(fileID: "a", name: "A.pdf", mimeType: "application/pdf", sizeBytes: 100)
        tracker.recordAccess(fileID: "a", name: "A.pdf", mimeType: "application/pdf", sizeBytes: 100)
        tracker.recordAccess(fileID: "b", name: "B.pdf", mimeType: "application/pdf", sizeBytes: 200)

        XCTAssertEqual(tracker.record(for: "a")?.accessCount, 2)
        XCTAssertEqual(tracker.record(for: "b")?.accessCount, 1)
        XCTAssertEqual(tracker.allRecords.count, 2)
    }

    func test_tracker_persistsAcrossInstances() throws {
        try XCTSkipUnless(FeatureFlags.smartOfflineSync, "feature disabled")
        let first = FileAccessTracker(storageDirectory: tempDir)
        first.recordAccess(fileID: "x", name: "X", mimeType: "text/plain", sizeBytes: 5)
        first.recordAccess(fileID: "x", name: "X", mimeType: "text/plain", sizeBytes: 5)

        let second = FileAccessTracker(storageDirectory: tempDir)
        XCTAssertEqual(second.record(for: "x")?.accessCount, 2)
    }

    /// A listing that omits size must not erase a size a previous download established.
    func test_tracker_neverOverwritesKnownSizeWithNil() throws {
        try XCTSkipUnless(FeatureFlags.smartOfflineSync, "feature disabled")
        let tracker = FileAccessTracker(storageDirectory: tempDir)
        tracker.recordAccess(fileID: "a", name: "A", mimeType: "video/mp4", sizeBytes: 999)
        tracker.recordAccess(fileID: "a", name: "A", mimeType: nil, sizeBytes: nil)
        XCTAssertEqual(tracker.record(for: "a")?.sizeBytes, 999)
        XCTAssertEqual(tracker.record(for: "a")?.mimeType, "video/mp4")
    }

    func test_tracker_scoreRewardsBothFrequencyAndRecency() {
        let now = Date()
        let frequentButOld = record("old", count: 20, daysAgo: 30, now: now)
        let rareButRecent  = record("new", count: 1,  daysAgo: 0,  now: now)
        let rareAndOld     = record("meh", count: 1,  daysAgo: 30, now: now)

        let sOld = FileAccessTracker.score(for: frequentButOld, now: now)
        let sNew = FileAccessTracker.score(for: rareButRecent, now: now)
        let sMeh = FileAccessTracker.score(for: rareAndOld, now: now)

        // A habitually-used file outranks a one-off, even a fresh one.
        XCTAssertGreaterThan(sOld, sNew)
        // Between two equally rare files, the recent one wins.
        XCTAssertGreaterThan(sNew, sMeh)
    }

    func test_tracker_rankedRecords_areOrderedByScoreDescending() throws {
        try XCTSkipUnless(FeatureFlags.smartOfflineSync, "feature disabled")
        let tracker = FileAccessTracker(storageDirectory: tempDir)
        tracker.recordAccess(fileID: "low",  name: "L", mimeType: nil, sizeBytes: 1)
        for _ in 0..<5 { tracker.recordAccess(fileID: "high", name: "H", mimeType: nil, sizeBytes: 1) }

        XCTAssertEqual(tracker.rankedRecords().map(\.id), ["high", "low"])
    }

    func test_tracker_prunesStaleSingleAccessRecords() throws {
        try XCTSkipUnless(FeatureFlags.smartOfflineSync, "feature disabled")
        let tracker = FileAccessTracker(storageDirectory: tempDir)
        let old = Date().addingTimeInterval(-100 * 86_400)
        tracker.recordAccess(fileID: "stale", name: "S", mimeType: nil, sizeBytes: 1, at: old)
        // Repeatedly-used files survive even when old — habit is the signal, not freshness.
        tracker.recordAccess(fileID: "habit", name: "H", mimeType: nil, sizeBytes: 1, at: old)
        tracker.recordAccess(fileID: "habit", name: "H", mimeType: nil, sizeBytes: 1, at: old)

        tracker.prune()

        XCTAssertNil(tracker.record(for: "stale"))
        XCTAssertNotNil(tracker.record(for: "habit"))
    }

    func test_tracker_resetClearsEverything() throws {
        try XCTSkipUnless(FeatureFlags.smartOfflineSync, "feature disabled")
        let tracker = FileAccessTracker(storageDirectory: tempDir)
        tracker.recordAccess(fileID: "a", name: "A", mimeType: nil, sizeBytes: 1)
        tracker.reset()
        XCTAssertTrue(tracker.allRecords.isEmpty)
        XCTAssertTrue(FileAccessTracker(storageDirectory: tempDir).allRecords.isEmpty)
    }

    // MARK: - Budget

    func test_plan_neverExceedsBudget() {
        let mb: Int64 = 1024 * 1024
        let candidates = (0..<20).map { record("f\($0)", count: 20 - $0, daysAgo: 0, size: 30 * mb) }

        let plan = SmartOfflineSyncService.makePlan(candidates: candidates,
                                                    existing: [],
                                                    budgetBytes: 100 * mb)

        let total = plan.toDownload.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        XCTAssertLessThanOrEqual(total, 100 * mb)
        XCTAssertEqual(plan.toDownload.count, 3, "100 MB budget fits exactly three 30 MB files")
    }

    func test_plan_prefersHigherScoringCandidates() {
        let mb: Int64 = 1024 * 1024
        let candidates = [
            record("rare",   count: 1,  daysAgo: 20, size: 40 * mb),
            record("common", count: 50, daysAgo: 0,  size: 40 * mb),
        ]
        let plan = SmartOfflineSyncService.makePlan(candidates: candidates,
                                                    existing: [],
                                                    budgetBytes: 50 * mb)
        XCTAssertEqual(plan.toDownload.map(\.id), ["common"])
    }

    func test_plan_skipsFilesAlreadyOffline() {
        let mb: Int64 = 1024 * 1024
        let candidates = [record("a", count: 5, daysAgo: 0, size: 10 * mb),
                          record("b", count: 4, daysAgo: 0, size: 10 * mb)]
        let plan = SmartOfflineSyncService.makePlan(
            candidates: candidates,
            existing: [offline("a", size: 10 * mb, managed: true)],
            budgetBytes: 500 * mb
        )
        XCTAssertEqual(plan.toDownload.map(\.id), ["b"])
    }

    /// An unknown size is skipped, never guessed. Admitting a file of unknown size is exactly
    /// how a storage budget stops being a budget.
    func test_plan_skipsCandidatesWithUnknownSize() {
        let plan = SmartOfflineSyncService.makePlan(
            candidates: [record("unknown", count: 99, daysAgo: 0, size: nil)],
            existing: [],
            budgetBytes: 500 * 1024 * 1024
        )
        XCTAssertTrue(plan.toDownload.isEmpty)
    }

    /// A file bigger than the entire budget must be skipped, not cause everything else to be
    /// evicted in a doomed attempt to fit it.
    func test_plan_skipsFileLargerThanWholeBudget() {
        let mb: Int64 = 1024 * 1024
        let plan = SmartOfflineSyncService.makePlan(
            candidates: [record("huge", count: 99, daysAgo: 0, size: 900 * mb),
                         record("small", count: 1, daysAgo: 0, size: 10 * mb)],
            existing: [offline("keep", size: 50 * mb, managed: true)],
            budgetBytes: 100 * mb
        )
        XCTAssertFalse(plan.toDownload.contains { $0.id == "huge" })
        XCTAssertFalse(plan.toEvict.contains("keep"), "nothing should be evicted for a file that cannot fit")
    }

    // MARK: - Eviction

    func test_plan_evictsLowestScoringManagedFileToMakeRoom() {
        let mb: Int64 = 1024 * 1024
        let now = Date()
        let candidates = [
            record("hot",  count: 50, daysAgo: 0,  size: 60 * mb, now: now),   // wants in
            record("cold", count: 1,  daysAgo: 30, size: 60 * mb, now: now),   // already cached
        ]
        let plan = SmartOfflineSyncService.makePlan(
            candidates: candidates,
            existing: [offline("cold", size: 60 * mb, managed: true)],
            budgetBytes: 100 * mb,
            now: now
        )
        XCTAssertEqual(plan.toEvict, ["cold"])
        XCTAssertEqual(plan.toDownload.map(\.id), ["hot"])
    }

    /// **The invariant that matters most in this feature.** An automatic cache that can delete
    /// a file the user explicitly pinned is a bug that only shows up when they have no signal.
    func test_plan_neverEvictsUserPinnedFiles() {
        let mb: Int64 = 1024 * 1024
        let now = Date()
        let plan = SmartOfflineSyncService.makePlan(
            candidates: [record("hot", count: 99, daysAgo: 0, size: 90 * mb, now: now)],
            existing: [offline("pinned", size: 500 * mb, managed: false)],
            budgetBytes: 100 * mb,
            now: now
        )
        XCTAssertTrue(plan.toEvict.isEmpty, "a pinned file must never be evicted")
        // And the pinned file's size does not consume the automatic budget, so caching proceeds.
        XCTAssertEqual(plan.toDownload.map(\.id), ["hot"])
    }

    /// Eviction must not churn: a weaker candidate must not displace a stronger cached file.
    func test_plan_doesNotEvictAHigherScoringFileForALowerScoringOne() {
        let mb: Int64 = 1024 * 1024
        let now = Date()
        let plan = SmartOfflineSyncService.makePlan(
            candidates: [record("weak",   count: 1,  daysAgo: 10, size: 60 * mb, now: now),
                         record("strong", count: 90, daysAgo: 0,  size: 60 * mb, now: now)],
            existing: [offline("strong", size: 60 * mb, managed: true)],
            budgetBytes: 100 * mb,
            now: now
        )
        XCTAssertTrue(plan.toEvict.isEmpty)
        XCTAssertTrue(plan.toDownload.isEmpty)
    }

    func test_plan_respectsPerPassDownloadCap() {
        let mb: Int64 = 1024 * 1024
        let candidates = (0..<50).map { record("f\($0)", count: 50 - $0, daysAgo: 0, size: 1 * mb) }
        let plan = SmartOfflineSyncService.makePlan(candidates: candidates,
                                                    existing: [],
                                                    budgetBytes: 500 * mb,
                                                    maxDownloadsPerPass: 4)
        XCTAssertEqual(plan.toDownload.count, 4)
    }

    // MARK: - Constraints

    func test_constraints_blockWhenOffWiFiAndWiFiOnly() throws {
        try XCTSkipUnless(FeatureFlags.smartOfflineSync, "feature disabled")
        XCTAssertFalse(SmartOfflineSyncService.constraintsSatisfied(
            enabled: true, wifiOnly: true, onWiFi: false,
            whileChargingOnly: false, isCharging: false))

        XCTAssertTrue(SmartOfflineSyncService.constraintsSatisfied(
            enabled: true, wifiOnly: true, onWiFi: true,
            whileChargingOnly: false, isCharging: false))
    }

    func test_constraints_blockWhenNotChargingAndChargingOnly() throws {
        try XCTSkipUnless(FeatureFlags.smartOfflineSync, "feature disabled")
        XCTAssertFalse(SmartOfflineSyncService.constraintsSatisfied(
            enabled: true, wifiOnly: false, onWiFi: true,
            whileChargingOnly: true, isCharging: false))

        XCTAssertTrue(SmartOfflineSyncService.constraintsSatisfied(
            enabled: true, wifiOnly: false, onWiFi: true,
            whileChargingOnly: true, isCharging: true))
    }

    func test_constraints_blockWhenDisabled() {
        XCTAssertFalse(SmartOfflineSyncService.constraintsSatisfied(
            enabled: false, wifiOnly: false, onWiFi: true,
            whileChargingOnly: false, isCharging: true))
    }

    /// Cellular is allowed only when the user has said so — the default must not spend data.
    func test_wifiOnly_defaultsToTrue() async {
        let defaults = UserDefaults(suiteName: "smartoffline-test-\(UUID().uuidString)")!
        let service = await SmartOfflineSyncService(defaults: defaults, startMonitoring: false)
        let wifiOnly = await service.wifiOnly
        let enabled = await service.isEnabled
        XCTAssertTrue(wifiOnly)
        XCTAssertFalse(enabled, "smart caching must be opt-in — the disk it fills is the user's")
    }

    // MARK: - OfflineService integration

    @MainActor
    func test_offlineService_evictManagedRefusesToDeleteAPinnedFile() throws {
        let fileURL = tempDir.appendingPathComponent("pinned.bin")
        try Data([1, 2, 3]).write(to: fileURL)

        let pinned = OfflineFile(id: "p", name: "pinned.bin", mimeType: "application/octet-stream",
                                 sizeBytes: 3, localURL: fileURL, cachedAt: Date(),
                                 isManaged: false)
        let service = OfflineService(offlineFiles: [pinned], storageDirectory: tempDir)

        service.evictManaged(fileID: "p")

        XCTAssertTrue(service.isOffline(fileID: "p"), "pinned entry must survive eviction")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "pinned file must still be on disk")
    }

    @MainActor
    func test_offlineService_evictManagedRemovesAManagedFile() throws {
        let fileURL = tempDir.appendingPathComponent("cached.bin")
        try Data([1, 2, 3]).write(to: fileURL)

        let managed = OfflineFile(id: "m", name: "cached.bin", mimeType: "application/octet-stream",
                                  sizeBytes: 3, localURL: fileURL, cachedAt: Date(),
                                  isManaged: true)
        let service = OfflineService(offlineFiles: [managed], storageDirectory: tempDir)

        service.evictManaged(fileID: "m")

        XCTAssertFalse(service.isOffline(fileID: "m"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func test_offlineService_separatesManagedAndPinnedTotals() throws {
        let a = tempDir.appendingPathComponent("a.bin"), b = tempDir.appendingPathComponent("b.bin")
        try Data(repeating: 0, count: 10).write(to: a)
        try Data(repeating: 0, count: 20).write(to: b)

        let service = OfflineService(offlineFiles: [
            OfflineFile(id: "a", name: "a.bin", mimeType: "x", sizeBytes: 10, localURL: a,
                        cachedAt: Date(), isManaged: true),
            OfflineFile(id: "b", name: "b.bin", mimeType: "x", sizeBytes: 20, localURL: b,
                        cachedAt: Date(), isManaged: false),
        ], storageDirectory: tempDir)

        XCTAssertEqual(service.managedCacheSizeBytes(), 10)
        XCTAssertEqual(service.pinnedCacheSizeBytes(), 20)
        XCTAssertEqual(service.cacheSizeBytes(), 30)
    }

    /// The budget is enforced against the filesystem, not against a running total, so a stale
    /// or optimistic manifest entry cannot silently inflate the accounting.
    @MainActor
    func test_offlineService_actualManagedSizeIsRecomputedFromDisk() throws {
        let a = tempDir.appendingPathComponent("real.bin")
        try Data(repeating: 0, count: 64).write(to: a)

        let service = OfflineService(offlineFiles: [
            // Manifest claims 9999 bytes; the file is 64.
            OfflineFile(id: "a", name: "real.bin", mimeType: "x", sizeBytes: 9999, localURL: a,
                        cachedAt: Date(), isManaged: true),
            // And an entry whose file no longer exists at all.
            OfflineFile(id: "ghost", name: "gone.bin", mimeType: "x", sizeBytes: 500,
                        localURL: tempDir.appendingPathComponent("gone.bin"),
                        cachedAt: Date(), isManaged: true),
        ], storageDirectory: tempDir)

        XCTAssertEqual(service.managedCacheSizeBytes(), 10_499, "manifest total")
        XCTAssertEqual(service.actualManagedCacheSizeBytes(), 64, "on-disk total")
    }

    /// An older manifest written before `isManaged` existed must decode, and must decode as
    /// *pinned* — the safe reading, since treating it as managed would make it evictable.
    func test_offlineFile_decodesLegacyManifestWithoutIsManaged() throws {
        let json = """
        [{"id":"a","name":"A.pdf","mimeType":"application/pdf","sizeBytes":10,
          "localURL":"file:///tmp/a.pdf","cachedAt":"2024-01-01T00:00:00Z"}]
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files = try decoder.decode([OfflineFile].self, from: json)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].isManaged, "a legacy entry must be treated as user-pinned")
    }
}
