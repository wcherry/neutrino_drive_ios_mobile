import XCTest
import Photos
@testable import NeutrinoDrive

// MARK: - Fakes

/// `PHAsset` cannot be constructed in a test target, so `PhotoSyncService`'s change-detection
/// logic is driven through this fake conforming to `PhotoAssetProviding`.
private struct FakePhotoAsset: PhotoAssetProviding {
    let localIdentifier: String
    let creationDate: Date?
    var mediaType: PHAssetMediaType = .image
}

/// Returns canned bytes instantly instead of touching PhotoKit.
private struct FakeAssetExporter: PhotoAssetExporting {
    var data: Data = Data("fake-photo-bytes".utf8)
    var fileName: String = "IMG_0001.jpg"
    var mimeType: String = "image/jpeg"

    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport {
        PhotoExport(data: data, fileName: fileName, mimeType: mimeType)
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

    func test_drain_wifiOnlyOff_uploadsOverCellular() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = false
        sut.isNetworkExpensive = true
        sut.wifiOnly = false
        sut.folderResolver = { _, _ in "folder-1" }
        sut.uploadHandler = { data, fileName, mimeType, parentFolderID in
            UploadResult(id: "file-1", name: fileName, folderId: parentFolderID,
                        sizeBytes: Int64(data.count), mimeType: mimeType, updatedAt: Date())
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
        sut.uploadHandler = { data, fileName, mimeType, parentFolderID in
            uploadCallCount += 1
            receivedFolderIDs.append(parentFolderID)
            if uploadCallCount == 1 {
                throw UploadError.serverError(statusCode: 404)
            }
            return UploadResult(id: "file-1", name: fileName, folderId: parentFolderID,
                                sizeBytes: Int64(data.count), mimeType: mimeType, updatedAt: Date())
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
        sut.uploadHandler = { data, fileName, mimeType, parentFolderID in
            UploadResult(id: "file-1", name: fileName, folderId: parentFolderID,
                        sizeBytes: Int64(data.count), mimeType: mimeType, updatedAt: Date())
        }

        sut.enqueueIfNeeded([FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date())])
        XCTAssertEqual(sut.pendingCount, 1)

        _ = await sut.drain(ignoringPowerConstraint: false)

        XCTAssertEqual(sut.pendingCount, 0)
        XCTAssertTrue(sut.debugIsCompleted("asset-1"))
        XCTAssertEqual(sut.status, .idle)
    }

    func test_drain_permanentServerError_movesEntryToFailedImmediately() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.folderResolver = { _, _ in "folder-1" }
        sut.uploadHandler = { _, _, _, _ in throw UploadError.serverError(statusCode: 403) }

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
        sut.uploadHandler = { _, _, _, _ in
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
        queue.completed = ["known"]

        let result = PhotoSyncService.newIdentifiers(from: [asset], anchorDate: anchor,
                                                      includeVideos: true, queue: queue)

        XCTAssertTrue(result.isEmpty)
    }

    func test_newIdentifiers_distantPastAnchor_includesAssetsWithNoCreationDate() {
        let dated   = FakePhotoAsset(localIdentifier: "dated", creationDate: Date(timeIntervalSince1970: 500))
        let undated = FakePhotoAsset(localIdentifier: "undated", creationDate: nil)

        let backfill = PhotoSyncService.newIdentifiers(from: [dated, undated], anchorDate: .distantPast,
                                                       includeVideos: true, queue: PhotoSyncQueue())
        XCTAssertEqual(Set(backfill.map(\.id)), ["dated", "undated"])

        // A normal (new-photos-only) anchor still skips an asset with no creation date.
        let normal = PhotoSyncService.newIdentifiers(from: [undated], anchorDate: Date(timeIntervalSince1970: 1000),
                                                     includeVideos: true, queue: PhotoSyncQueue())
        XCTAssertTrue(normal.isEmpty)
    }

    // MARK: - Existing-library backup

    func test_includeExistingPhotos_defaultsToOff_andExcludesPreAnchorAssets() {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date(timeIntervalSince1970: 1000), forKey: PhotoSyncService.Keys.anchorDate)
        XCTAssertFalse(sut.includeExistingPhotos)

        let old = FakePhotoAsset(localIdentifier: "old", creationDate: Date(timeIntervalSince1970: 10))
        let new = FakePhotoAsset(localIdentifier: "new", creationDate: Date(timeIntervalSince1970: 2000))

        XCTAssertEqual(sut.enqueueIfNeeded([old, new]), 1)
        XCTAssertNotNil(sut.debugPendingEntry("new"))
        XCTAssertNil(sut.debugPendingEntry("old"))
    }

    func test_includeExistingPhotos_on_enqueuesAssetsCreatedBeforeTheAnchor() {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date(timeIntervalSince1970: 1000), forKey: PhotoSyncService.Keys.anchorDate)
        defaults.set(true, forKey: PhotoSyncService.Keys.includeExisting)

        let old = FakePhotoAsset(localIdentifier: "old", creationDate: Date(timeIntervalSince1970: 10))
        let new = FakePhotoAsset(localIdentifier: "new", creationDate: Date(timeIntervalSince1970: 2000))

        XCTAssertEqual(sut.enqueueIfNeeded([old, new]), 2)
        XCTAssertNotNil(sut.debugPendingEntry("old"))
    }

    func test_includeExistingPhotos_turningOffAgain_stopsQueueingOlderAssets() {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date(timeIntervalSince1970: 1000), forKey: PhotoSyncService.Keys.anchorDate)
        sut.includeExistingPhotos = true
        sut.includeExistingPhotos = false

        let old = FakePhotoAsset(localIdentifier: "old", creationDate: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(sut.enqueueIfNeeded([old]), 0)
    }

    func test_includeExistingPhotos_dedupesAgainstAlreadyUploadedAssets() async {
        let (sut, defaults) = makeSUT(enabled: true)
        defaults.set(Date.distantPast, forKey: PhotoSyncService.Keys.anchorDate)
        defaults.set(true, forKey: PhotoSyncService.Keys.includeExisting)
        sut.hasAccessTokenProvider = { true }
        sut.hasStoredKeysProvider = { true }
        sut.isOnWiFi = true
        sut.folderResolver = { _, _ in "folder-1" }
        sut.uploadHandler = { data, fileName, mimeType, parentFolderID in
            UploadResult(id: "file-1", name: fileName, folderId: parentFolderID,
                         sizeBytes: Int64(data.count), mimeType: mimeType, updatedAt: Date())
        }

        let asset = FakePhotoAsset(localIdentifier: "asset-1", creationDate: Date(timeIntervalSince1970: 10))
        sut.enqueueIfNeeded([asset])
        _ = await sut.drain(ignoringPowerConstraint: false)
        XCTAssertTrue(sut.debugIsCompleted("asset-1"))

        // A second sweep of the same library must not re-upload what is already in Drive.
        XCTAssertEqual(sut.enqueueIfNeeded([asset]), 0)
    }

    // MARK: - Default destination folder

    func test_defaultFolderName_isDeviceNamePlusPhotos() {
        XCTAssertEqual(PhotoSyncService.defaultFolderName, "\(PhotoSyncService.sanitizedDeviceName) Photos")
        XCTAssertTrue(PhotoSyncService.defaultFolderName.hasSuffix(" Photos"))
        XCTAssertFalse(PhotoSyncService.sanitizedDeviceName.isEmpty)
        XCTAssertFalse(PhotoSyncService.sanitizedDeviceName.contains("/"),
                       "path separators must never reach the server-side folder name")
    }

    func test_folderName_usesDefaultUntilOverridden_andClearsCachedFolderID() {
        let (sut, defaults) = makeSUT(enabled: true)
        XCTAssertEqual(sut.folderName, PhotoSyncService.defaultFolderName)

        defaults.set("cached-folder-id", forKey: PhotoSyncService.Keys.folderID)
        sut.folderName = "Camera Roll Backup"

        XCTAssertEqual(sut.folderName, "Camera Roll Backup")
        XCTAssertNil(defaults.string(forKey: PhotoSyncService.Keys.folderID),
                     "renaming the destination must force the folder to be re-resolved")
    }

    // MARK: - Enable / permission handling

    func test_isEnabled_setToFalse_setsStatusDisabled() {
        let (sut, _) = makeSUT(enabled: true)
        sut.isEnabled = false
        XCTAssertEqual(sut.status, .disabled)
    }
}
