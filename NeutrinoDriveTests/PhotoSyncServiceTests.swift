import XCTest
import Photos
@testable import NeutrinoDrive

// MARK: - Fakes

/// `PHAsset` cannot be constructed in a test target, so `PhotoSyncService`'s change-detection
/// logic is driven through this fake conforming to `PhotoAssetProviding`.
private struct FakePhotoAsset: PhotoAssetProviding {
    let localIdentifier: String
    let creationDate: Date?
    var modificationDate: Date?
    var mediaType: PHAssetMediaType = .image
}

/// Returns canned bytes instantly instead of touching PhotoKit.
private struct FakeAssetExporter: PhotoAssetExporting {
    var data: Data = Data("fake-photo-bytes".utf8)
    var fileName: String = "IMG_0001.jpg"
    var mimeType: String = "image/jpeg"
    /// What the real exporter fills in for videos, from the temp file it already wrote.
    var thumbnailBase64: String?

    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport {
        PhotoExport(data: data, fileName: fileName, mimeType: mimeType,
                    thumbnailBase64: thumbnailBase64)
    }
}

/// Names the exported file after the asset identifier, so a test can assert the *order* in
/// which the drain loop picked entries off the queue.
private struct IdentifyingAssetExporter: PhotoAssetExporting {
    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport {
        PhotoExport(data: Data("bytes".utf8), fileName: identifier, mimeType: "image/jpeg")
    }
}

// MARK: - PhotoSyncServiceTests

@MainActor
final class PhotoSyncServiceTests: XCTestCase {

    // MARK: - Fixtures

    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "PhotoSyncServiceTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    private func makeStore() -> PhotoSyncQueueStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        return PhotoSyncQueueStore(fileURL: url)
    }

    private func makeSUT(enabled: Bool = false, defaults: UserDefaults? = nil,
                         exporter: PhotoAssetExporting = FakeAssetExporter()) -> (PhotoSyncService, UserDefaults) {
        let defaults = defaults ?? makeDefaults()
        if enabled { defaults.set(true, forKey: PhotoSyncService.Keys.enabled) }
        let sut = PhotoSyncService(defaults: defaults, queueStore: makeStore(), assetExporter: exporter)
        return (sut, defaults)
    }

    // MARK: - Disabled flag

    func test_start_whenDisabled_setsStatusDisabled() {
        let (sut, _) = makeSUT(enabled: false)

        sut.start()

        // With isEnabled == false, `start()` returns immediately after setting `.disabled` —
        // it never reaches the PHPhotoLibrary observer-registration or
        // requestAuthorization(for:) calls that live further down the method.
        XCTAssertEqual(sut.status, .disabled)
    }

    func test_init_whenDisabled_statusIsDisabled() {
        let (sut, _) = makeSUT(enabled: false)
        XCTAssertEqual(sut.status, .disabled)
        XCTAssertFalse(sut.isEnabled)
    }

    // MARK: - Wi-Fi-only constraint

    func test_drain_wifiOnlyWithCellularPath_isNoOpAndQueueUntouched() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = false
        sut.isNetworkExpensive = true
        XCTAssertTrue(sut.wifiOnly, "wifiOnly should default to true")

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        XCTAssertEqual(sut.pendingCount, 1)

        let didWork = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertFalse(didWork)
        XCTAssertEqual(sut.pendingCount, 1, "queue must be untouched while waiting for Wi-Fi")
        XCTAssertEqual(sut.status, .waitingForWiFi)
    }

    // MARK: - Cover thumbnails

    func test_drain_forwardsTheExportersCoverThumbnailToTheUpload() async {
        // The exporter is the only part of the pipeline holding a video as a file, so the cover
        // it makes is the one that has to survive the trip. Dropping it here is invisible —
        // the upload succeeds either way and the clip simply has no tile.
        let exporter = FakeAssetExporter(data: Data("fake-video-bytes".utf8),
                                         fileName: "IMG_0002.mov",
                                         mimeType: "video/quicktime",
                                         thumbnailBase64: "POSTER-FRAME")
        let (sut, defaults) = makeSUT(enabled: true, exporter: exporter)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.folderResolver = { _, _ in "folder-1" }

        var receivedThumbnail: String?
        sut.uploadHandler = { export, parentFolderID, _ in
            receivedThumbnail = export.thumbnailBase64
            return UploadResult(id: "file-1", name: export.fileName, folderId: parentFolderID,
                                sizeBytes: Int64(export.data.count), mimeType: export.mimeType,
                                updatedAt: Date())
        }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(receivedThumbnail, "POSTER-FRAME")
    }

    func test_drain_leavesTheCoverNil_whenTheExporterHasNone() async {
        // An image's cover is derived downstream from the same bytes being uploaded, so the
        // exporter deliberately supplies nothing and `E2EEUploader` makes it.
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.folderResolver = { _, _ in "folder-1" }

        var sawThumbnail: String? = "sentinel"
        sut.uploadHandler = { export, parentFolderID, _ in
            sawThumbnail = export.thumbnailBase64
            return UploadResult(id: "file-1", name: export.fileName, folderId: parentFolderID,
                                sizeBytes: Int64(export.data.count), mimeType: export.mimeType,
                                updatedAt: Date())
        }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertNil(sawThumbnail)
    }

    func test_drain_wifiOnlyOff_uploadsOverCellular() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = false
        sut.isNetworkExpensive = true
        sut.wifiOnly = false
        sut.folderResolver = { _, _ in "folder-1" }
        sut.uploadHandler = { export, parentFolderID, _ in
            UploadResult(id: "file-1", name: export.fileName, folderId: parentFolderID,
                        sizeBytes: Int64(export.data.count), mimeType: export.mimeType,
                        updatedAt: Date())
        }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        let didWork = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertTrue(didWork)
        XCTAssertEqual(sut.pendingCount, 0)
    }

    // MARK: - Missing encryption key

    func test_drain_missingEncryptionKey_pausesAndDequeuesNothing() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { false }
        sut.isOnWiFi = true

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        XCTAssertEqual(sut.pendingCount, 1)

        let didWork = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertFalse(didWork)
        XCTAssertEqual(sut.pendingCount, 1)
        XCTAssertEqual(sut.status, .pausedMissingKey)
    }

    func test_drain_missingAccessToken_pauses() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { false }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        let didWork = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertFalse(didWork)
        XCTAssertEqual(sut.status, .pausedNotAuthenticated)
    }

    // MARK: - Folder resolution

    func test_resolveDestinationFolder_usesCachedID_whenPresent() async throws {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set("cached-folder-id", forKey: PhotoSyncService.Keys.folderID)
        sut.folderResolver = { _, _ in
            XCTFail("folderResolver must not be called when a cached ID is present")
            return "unused"
        }

        let result = try await sut.resolveDestinationFolder()

        XCTAssertEqual(result, "cached-folder-id")
    }

    func test_resolveDestinationFolder_missingID_callsResolverAndCachesResult() async throws {
        let (sut, defaults) = makeSUT(enabled: true)
        var receivedName: String?
        var receivedParentID: String? = "not-nil-sentinel"
        sut.folderResolver = { name, parentID in
            receivedName = name
            receivedParentID = parentID
            return "created-folder-id"
        }

        let result = try await sut.resolveDestinationFolder()

        XCTAssertEqual(result, "created-folder-id")
        XCTAssertEqual(receivedName, PhotoSyncService.defaultFolderName)
        XCTAssertNil(receivedParentID)
        XCTAssertEqual(defaults.string(forKey: PhotoSyncService.Keys.folderID), "created-folder-id")
    }

    func test_drain_uploadFails404_clearsCachedFolderID_andRetriesExactlyOnce() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        defaults.set("stale-folder-id", forKey: PhotoSyncService.Keys.folderID)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true

        var resolverCallCount = 0
        sut.folderResolver = { _, _ in
            resolverCallCount += 1
            return "fresh-folder-id"
        }

        var uploadCallCount = 0
        var receivedFolderIDs: [String?] = []
        sut.uploadHandler = { export, parentFolderID, _ in
            uploadCallCount += 1
            receivedFolderIDs.append(parentFolderID)
            if uploadCallCount == 1 {
                throw UploadError.serverError(statusCode: 404)
            }
            return UploadResult(id: "file-1", name: export.fileName, folderId: parentFolderID,
                                sizeBytes: Int64(export.data.count), mimeType: export.mimeType,
                                updatedAt: Date())
        }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(uploadCallCount, 2, "should retry the upload once after re-resolving the folder")
        XCTAssertEqual(resolverCallCount, 1, "resolver runs once — only for the retry, since the first attempt used the cached ID")
        XCTAssertEqual(receivedFolderIDs, ["stale-folder-id", "fresh-folder-id"])
        XCTAssertEqual(defaults.string(forKey: PhotoSyncService.Keys.folderID), "fresh-folder-id")
        XCTAssertTrue(sut.debugIsCompleted("asset-1"))
    }

    // MARK: - Successful upload

    func test_drain_successfulUpload_movesEntryFromPendingToCompleted() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.folderResolver = { _, _ in "folder-1" }
        sut.uploadHandler = { export, parentFolderID, _ in
            UploadResult(id: "file-1", name: export.fileName, folderId: parentFolderID,
                        sizeBytes: Int64(export.data.count), mimeType: export.mimeType,
                        updatedAt: Date())
        }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        XCTAssertEqual(sut.pendingCount, 1)

        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(sut.pendingCount, 0)
        XCTAssertTrue(sut.debugIsCompleted("asset-1"))
        XCTAssertEqual(sut.status, .idle)
    }

    // MARK: - Access-token freshness

    /// The regression that made background sync useless in practice. Access tokens last 15
    /// minutes, and `E2EEUploader` reads its bearer token straight out of the Keychain so the
    /// share extension can upload without an `AuthService`. Every *other* caller reaches the
    /// server through `DriveService`, which renews on the way past — but once the destination
    /// folder ID is cached, an upload never touches `DriveService` at all. In the foreground
    /// that is invisible, because the user browsing Drive keeps the token fresh; a drain with
    /// the app off screen has nothing keeping it fresh, so it must do it itself.
    func test_drain_renewsTheAccessTokenBeforeUploading() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.folderResolver = { _, _ in "folder-1" }

        var events: [String] = []
        sut.tokenRefresher = { events.append("refresh") }
        sut.uploadHandler = { export, parentFolderID, _ in
            events.append("upload")
            return UploadResult(id: "file-1", name: export.fileName, folderId: parentFolderID,
                                sizeBytes: Int64(export.data.count), mimeType: export.mimeType,
                                updatedAt: Date())
        }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(events, ["refresh", "upload"],
                       "The token must be renewed before the bytes go out, not after")
    }

    /// `drain` runs on every network path change, so an unconditional refresh would spend a
    /// token round trip every time Wi-Fi flickers with nothing queued.
    func test_drain_withNothingQueued_doesNotRenewTheToken() async {
        let (sut, _) = makeSUT(enabled: true)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true

        var refreshCount = 0
        sut.tokenRefresher = { refreshCount += 1 }

        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(refreshCount, 0)
    }

    /// A 401 is a stale token, not a rejected photo. Classifying it as permanent is what sent
    /// every photo a background drain touched to `failed` on its *first* attempt, where only
    /// "Retry Failed" in Settings could reach it.
    func test_drain_unauthorized_leavesEntryPendingRatherThanFailingItPermanently() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.folderResolver = { _, _ in "folder-1" }
        sut.tokenRefresher = {}
        sut.uploadHandler = { _, _, _ in throw UploadError.serverError(statusCode: 401) }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertNil(sut.debugFailedEntry("asset-1"), "401 must never be recorded as permanent")
        XCTAssertEqual(sut.pendingCount, 1)
        XCTAssertEqual(sut.debugPendingEntry("asset-1")?.attempts, 1)
        XCTAssertNotNil(sut.debugPendingEntry("asset-1")?.nextAttemptAfter,
                        "A retryable failure must be scheduled for backoff")
    }

    /// The token can also expire *during* a drain — a long backlog on a slow link outlives 15
    /// minutes easily — so one 401 is recovered in place rather than costing the photo an
    /// attempt. Distinct from the 404 path: a 401 says nothing about the cached folder.
    func test_drain_unauthorizedThenRenewed_uploadsWithoutCostingAnAttempt() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        defaults.set("cached-folder", forKey: PhotoSyncService.Keys.folderID)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.folderResolver = { _, _ in
            XCTFail("A 401 must not invalidate the cached folder ID")
            return "unused"
        }

        var refreshCount = 0
        sut.tokenRefresher = { refreshCount += 1 }

        var uploadCallCount = 0
        sut.uploadHandler = { export, parentFolderID, _ in
            uploadCallCount += 1
            if uploadCallCount == 1 { throw UploadError.serverError(statusCode: 401) }
            return UploadResult(id: "file-1", name: export.fileName, folderId: parentFolderID,
                                sizeBytes: Int64(export.data.count), mimeType: export.mimeType,
                                updatedAt: Date())
        }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(uploadCallCount, 2)
        XCTAssertEqual(refreshCount, 2, "Once before the drain, once to recover the 401")
        XCTAssertTrue(sut.debugIsCompleted("asset-1"))
        XCTAssertEqual(sut.pendingCount, 0)
        XCTAssertEqual(sut.failedCount, 0)
    }

    // MARK: - Running out of background time

    /// A background drain is always racing a clock — the `BGProcessingTask` budget, or the
    /// grace period after the app leaves the foreground. What matters is that running out is
    /// *harmless*: the loop stops promptly, and the entries it never reached stay `pending`
    /// with an untouched retry budget. Charging them an attempt would burn a photo down to
    /// `failed` after five interrupted runs, stranding it behind a manual "Retry Failed".
    func test_drain_whenBackgroundTimeExpires_stopsAndLeavesUnreachedEntriesPending() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.folderResolver = { _, _ in "folder-1" }

        var uploadCallCount = 0
        sut.uploadHandler = { export, parentFolderID, _ in
            uploadCallCount += 1
            return UploadResult(id: "file-\(uploadCallCount)", name: export.fileName,
                                folderId: parentFolderID, sizeBytes: Int64(export.data.count),
                                mimeType: export.mimeType, updatedAt: Date())
        }

        // Distinct creation dates: `drainable()` orders oldest-first, so asset-1 is the one
        // the single permitted upload consumes.
        let base = Date(timeIntervalSince1970: 1_000_000)
        sut.enqueueIfNeeded([
            FakePhotoAsset(localIdentifier: "asset-1", creationDate: base),
            FakePhotoAsset(localIdentifier: "asset-2", creationDate: base.addingTimeInterval(1)),
            FakePhotoAsset(localIdentifier: "asset-3", creationDate: base.addingTimeInterval(2)),
        ])
        XCTAssertEqual(sut.pendingCount, 3)

        // Expires the moment the first upload lands.
        _ = await sut.drain(ignoringPowerConstraint: false,
                            isBackgroundExpired: { uploadCallCount >= 1 })

        XCTAssertEqual(uploadCallCount, 1, "Expiry must actually stop the loop, not just be recorded")
        XCTAssertTrue(sut.debugIsCompleted("asset-1"))
        XCTAssertEqual(sut.pendingCount, 2)
        XCTAssertEqual(sut.failedCount, 0, "An interrupted run must not consume anyone's retry budget")

        for id in ["asset-2", "asset-3"] {
            XCTAssertEqual(sut.debugPendingEntry(id)?.attempts, 0, "\(id) was never attempted")
            XCTAssertNil(sut.debugPendingEntry(id)?.nextAttemptAfter,
                         "\(id) must be eligible immediately on the next run, not sitting in backoff")
        }
    }

    func test_drain_permanentServerError_movesEntryToFailedImmediately() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.folderResolver = { _, _ in "folder-1" }
        sut.uploadHandler = { _, _, _ in throw UploadError.serverError(statusCode: 403) }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(sut.pendingCount, 0)
        XCTAssertNotNil(sut.debugFailedEntry("asset-1"))
        XCTAssertEqual(sut.debugFailedEntry("asset-1")?.attempts, 1)
    }

    func test_drain_oversizedAsset_movesToFailedWithoutUploading() async {
        let bigData = Data(count: Int(PhotoSyncService.maxAssetSizeBytes) + 1)
        let (sut, defaults) = makeSUT(enabled: true, exporter: FakeAssetExporter(data: bigData))
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.folderResolver = { _, _ in "folder-1" }
        sut.uploadHandler = { _, _, _ in
            XCTFail("upload should not be attempted for an oversized asset")
            throw UploadError.encryptionFailed
        }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertNotNil(sut.debugFailedEntry("asset-1"))
        XCTAssertEqual(sut.debugFailedEntry("asset-1")?.lastError, "Too large for automatic backup")
    }

    // MARK: - Change detection (pure function — no PhotoKit dependency)

    func test_newIdentifiers_excludesAssetsBeforeAnchorDate() {
        let anchor = Date(timeIntervalSince1970: 1000)
        let before = FakePhotoAsset(localIdentifier: "before", creationDate: Date(timeIntervalSince1970: 500))
        let after  = FakePhotoAsset(localIdentifier: "after",  creationDate: Date(timeIntervalSince1970: 1500))

        let result = PhotoSyncService.newIdentifiers(from: [before, after], anchorDate: anchor,
                                                      includeVideos: true, queue: PhotoSyncQueue())

        XCTAssertEqual(result.map(\.id), ["after"])
    }

    func test_newIdentifiers_excludesVideos_whenIncludeVideosFalse() {
        let anchor = Date(timeIntervalSince1970: 0)
        let photo = FakePhotoAsset(localIdentifier: "photo", creationDate: Date(), mediaType: .image)
        let video = FakePhotoAsset(localIdentifier: "video", creationDate: Date(), mediaType: .video)

        let result = PhotoSyncService.newIdentifiers(from: [photo, video], anchorDate: anchor,
                                                      includeVideos: false, queue: PhotoSyncQueue())

        XCTAssertEqual(result.map(\.id), ["photo"])
    }

    func test_newIdentifiers_excludesAlreadyKnownIdentifiers() {
        let anchor = Date(timeIntervalSince1970: 0)
        let asset = FakePhotoAsset(localIdentifier: "known", creationDate: Date())
        var queue = PhotoSyncQueue()
        queue.completed = ["known": .init(fileID: "file-1")]

        let result = PhotoSyncService.newIdentifiers(from: [asset], anchorDate: anchor,
                                                      includeVideos: true, queue: queue)

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Backfill window (older photos)

    func test_backfillDays_defaultsToOff() {
        let (sut, _) = makeSUT(enabled: true)
        XCTAssertEqual(sut.backfillDays, 0)
        XCTAssertEqual(PhotoBackfillWindow(days: sut.backfillDays), .off)
    }

    func test_backfillCutoff_whenOff_isTheAnchorDate() {
        let anchor = Date(timeIntervalSince1970: 1_000_000)

        let cutoff = PhotoSyncService.backfillCutoff(days: 0, anchorDate: anchor, now: anchor)

        XCTAssertEqual(cutoff, anchor)
    }

    func test_backfillCutoff_withWindow_reachesThatManyDaysBeforeNow() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let anchor = now   // just switched on

        let cutoff = PhotoSyncService.backfillCutoff(days: 30, anchorDate: anchor, now: now)

        let expected = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        XCTAssertEqual(cutoff, expected)
    }

    func test_backfillCutoff_neverNarrowsAnAlreadyEarlierAnchor() {
        // An anchor from months ago already reaches further back than a 7-day window; the
        // window must not pull the cutoff forward and start skipping assets.
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let anchor = now.addingTimeInterval(-90 * 86_400)

        let cutoff = PhotoSyncService.backfillCutoff(days: 7, anchorDate: anchor, now: now)

        XCTAssertEqual(cutoff, anchor)
    }

    func test_backfillCutoff_allPhotos_isDistantPast() {
        let cutoff = PhotoSyncService.backfillCutoff(days: -1, anchorDate: Date(), now: Date())
        XCTAssertEqual(cutoff, .distantPast)
    }

    func test_enqueueIfNeeded_withBackfillWindow_acceptsAssetsOlderThanTheAnchor() {
        let (sut, defaults) = makeSUT(enabled: true)
        let anchor = Date()
        defaults.set(anchor, forKey: PhotoSyncService.Keys.anchorDate)
        let tenDaysOld = anchor.addingTimeInterval(-10 * 86_400)

        // Off: an asset from before the anchor is not our business.
        XCTAssertEqual(sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "old", creationDate: tenDaysOld)]), 0)

        sut.backfillDays = 30
        XCTAssertEqual(sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "old", creationDate: tenDaysOld)]), 1)
        XCTAssertNotNil(sut.debugPendingEntry("old"))
    }

    func test_enqueueIfNeeded_withBackfillWindow_stillExcludesAssetsOlderThanTheWindow() {
        let (sut, defaults) = makeSUT(enabled: true)
        let anchor = Date()
        defaults.set(anchor, forKey: PhotoSyncService.Keys.anchorDate)
        sut.backfillDays = 7

        let count = sut.enqueueIfNeeded([
            FakePhotoAsset(localIdentifier: "just-inside", creationDate: anchor.addingTimeInterval(-6 * 86_400)),
            FakePhotoAsset(localIdentifier: "too-old", creationDate: anchor.addingTimeInterval(-60 * 86_400)),
        ])

        XCTAssertEqual(count, 1)
        XCTAssertNotNil(sut.debugPendingEntry("just-inside"))
        XCTAssertNil(sut.debugPendingEntry("too-old"))
    }

    func test_enqueueIfNeeded_withoutAnchor_ignoresBackfillWindow() {
        // No anchor means the feature was never switched on. A stale window setting must not
        // be able to turn that into "upload the library".
        let (sut, _) = makeSUT(enabled: true)
        sut.backfillDays = 365

        let count = sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])

        XCTAssertEqual(count, 0)
    }

    func test_backfillWindow_roundsAnUnknownDayCountUpToTheNextWidestPreset() {
        XCTAssertEqual(PhotoBackfillWindow(days: 0), .off)
        XCTAssertEqual(PhotoBackfillWindow(days: 7), .week)
        XCTAssertEqual(PhotoBackfillWindow(days: 14), .month)
        XCTAssertEqual(PhotoBackfillWindow(days: 400), .all)
        XCTAssertEqual(PhotoBackfillWindow(days: -1), .all)
    }

    func test_drain_uploadsNewPhotosBeforeTheBackfillBacklog() async {
        let (sut, defaults) = makeSUT(enabled: true)
        let anchor = Date()
        defaults.set(anchor, forKey: PhotoSyncService.Keys.anchorDate)
        sut.backfillDays = 30
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.folderResolver = { _, _ in "folder-1" }

        // The exporter names each file after its identifier, so the upload order is observable.
        sut.assetExporter = IdentifyingAssetExporter()
        var uploadOrder: [String] = []
        sut.uploadHandler = { export, parentFolderID, _ in
            uploadOrder.append(export.fileName)
            return UploadResult(id: "file-1", name: export.fileName, folderId: parentFolderID,
                                sizeBytes: Int64(export.data.count), mimeType: export.mimeType,
                                updatedAt: Date())
        }

        sut.enqueueIfNeeded([
            FakePhotoAsset(localIdentifier: "backlog", creationDate: anchor.addingTimeInterval(-10 * 86_400)),
            FakePhotoAsset(localIdentifier: "new", creationDate: anchor.addingTimeInterval(60)),
        ])
        XCTAssertEqual(sut.pendingCount, 2)

        _ = await sut.drain(ignoringPowerConstraint: true)

        XCTAssertEqual(uploadOrder, ["new", "backlog"])
    }

    // MARK: - Capture dates (issue #31)
    //
    // Nothing in the upload request carries a date, so the server stamps its own clock and a
    // year of camera roll lands on the afternoon it was uploaded. The correction is a second
    // call, after the content — the content write is what sets `updated_at`, so a date sent
    // with the upload would be overwritten a moment later.

    /// Wires a service whose upload always succeeds, and captures what gets stamped.
    private func makeStampingSUT(
        exporter: PhotoAssetExporting = FakeAssetExporter(),
        stamp: @escaping (String, DriveImportMetadata) async throws -> Void
    ) -> PhotoSyncService {
        let (sut, defaults) = makeSUT(enabled: true, exporter: exporter)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.folderResolver = { _, _ in "folder-1" }
        sut.uploadHandler = { export, parentFolderID, _ in
            UploadResult(id: "file-77", name: export.fileName, folderId: parentFolderID,
                         sizeBytes: Int64(export.data.count), mimeType: export.mimeType,
                         updatedAt: Date())
        }
        sut.importMetadataStamper = stamp
        return sut
    }

    func test_drain_stampsTheAssetsCaptureDateOnTheUploadedFile() async {
        let captured = Date(timeIntervalSince1970: 1_562_198_400)   // 2019-07-04
        var stamped: DriveImportMetadata?
        let sut = makeStampingSUT { _, metadata in stamped = metadata }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: captured)])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(stamped?.createdAt, captured)
    }

    func test_drain_stampsTheModificationDate_whenTheAssetHasOne() async {
        let captured = Date(timeIntervalSince1970: 1_562_198_400)
        let edited   = Date(timeIntervalSince1970: 1_700_000_000)
        var stamped: DriveImportMetadata?
        let sut = makeStampingSUT { _, metadata in stamped = metadata }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: captured,
                                            modificationDate: edited)])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(stamped?.createdAt, captured)
        XCTAssertEqual(stamped?.updatedAt, edited)
    }

    func test_drain_fallsBackToTheCaptureDate_whenTheAssetHasNoModificationDate() async {
        let captured = Date(timeIntervalSince1970: 1_562_198_400)
        var stamped: DriveImportMetadata?
        let sut = makeStampingSUT { _, metadata in stamped = metadata }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: captured)])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(stamped?.updatedAt, captured)
    }

    func test_drain_stampsThePhotoSyncImportSource_carryingTheAssetIdentifier() async {
        var stamped: DriveImportMetadata?
        let sut = makeStampingSUT { _, metadata in stamped = metadata }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(stamped?.importSource, "photo-sync:asset-1")
    }

    func test_drain_stampsTheFileTheUploadReturned() async {
        var stampedFileID: String?
        let sut = makeStampingSUT { fileID, _ in stampedFileID = fileID }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(stampedFileID, "file-77",
                       "uploadWithFolderRetry used to discard the UploadResult, which threw away the one id needed to patch the file")
    }

    func test_drain_recordsTheUploadedFileIDInTheCompletedLedger() async {
        let sut = makeStampingSUT { _, _ in }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(sut.debugCompletedFileID("asset-1"), "file-77")
    }

    /// The photo is already safely uploaded by the time the stamp runs. Failing the entry
    /// would send a good file back to `pending` and re-upload it on the next drain — a
    /// duplicate, to fix a wrong date.
    func test_drain_aFailedStamp_leavesTheEntryCompletedRatherThanFailed() async {
        struct StampError: Error {}
        let sut = makeStampingSUT { _, _ in throw StampError() }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertTrue(sut.debugIsCompleted("asset-1"))
        XCTAssertNil(sut.debugFailedEntry("asset-1"))
        XCTAssertEqual(sut.pendingCount, 0)
        XCTAssertEqual(sut.status, .idle)
    }

    /// Order matters and is not cosmetic: writing the body stamps `updated_at`, so the patch
    /// is only meaningful after the upload has returned.
    func test_drain_stampsAfterTheUploadNotBefore() async {
        var events: [String] = []
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.folderResolver = { _, _ in "folder-1" }
        sut.uploadHandler = { export, parentFolderID, _ in
            events.append("upload")
            return UploadResult(id: "file-77", name: export.fileName, folderId: parentFolderID,
                                sizeBytes: 1, mimeType: export.mimeType, updatedAt: Date())
        }
        sut.importMetadataStamper = { _, _ in events.append("stamp") }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(events, ["upload", "stamp"])
    }

    // MARK: - Enable / permission handling

    func test_isEnabled_setToFalse_setsStatusDisabled() {
        let (sut, _) = makeSUT(enabled: true)
        sut.isEnabled = false
        XCTAssertEqual(sut.status, .disabled)
    }
}
