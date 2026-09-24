import XCTest
@testable import NeutrinoDrive

/// The durability half of issue #33: a sealed DEK written before the ciphertext and removed
/// only once the key is safely on the server.
final class PendingUploadKeyStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeSUT() -> PendingUploadKeyStore {
        PendingUploadKeyStore(fileURL: fileURL)
    }

    private func makeKey(_ uploadID: String = "upload-1", fileID: String? = nil,
                         keyVersion: Int = 1, createdAt: Date = Date()) -> PendingUploadKey {
        PendingUploadKey(uploadID: uploadID, sealedFileKey: "SEALED-\(uploadID)",
                         keyVersion: keyVersion, fileName: "photo.heic",
                         fileID: fileID, createdAt: createdAt)
    }

    // MARK: - Round trip

    func test_record_thenKeyForUploadID_returnsIt() {
        let sut = makeSUT()
        sut.record(makeKey("upload-1"))

        XCTAssertEqual(sut.key(forUploadID: "upload-1")?.sealedFileKey, "SEALED-upload-1")
    }

    func test_keyForUploadID_isNilForAnUnknownUpload() {
        XCTAssertNil(makeSUT().key(forUploadID: "never-recorded"))
    }

    /// The whole point: the record has to outlive the process that wrote it. Anything less and
    /// the DEK still dies with the app.
    func test_record_survivesAFreshStoreOverTheSameFile() {
        makeSUT().record(makeKey("upload-1", keyVersion: 3))

        let reloaded = PendingUploadKeyStore(fileURL: fileURL).key(forUploadID: "upload-1")

        XCTAssertEqual(reloaded?.sealedFileKey, "SEALED-upload-1")
        XCTAssertEqual(reloaded?.keyVersion, 3, "A resumed upload must file its key under the version it was sealed to")
    }

    func test_record_replacesAnEarlierRecordForTheSameUpload() {
        let sut = makeSUT()
        sut.record(makeKey("upload-1"))
        sut.record(PendingUploadKey(uploadID: "upload-1", sealedFileKey: "SEALED-AGAIN",
                                    keyVersion: 2, fileName: "photo.heic",
                                    fileID: nil, createdAt: Date()))

        XCTAssertEqual(sut.all().count, 1)
        XCTAssertEqual(sut.key(forUploadID: "upload-1")?.sealedFileKey, "SEALED-AGAIN")
    }

    // MARK: - File id

    func test_attachFileID_marksTheBlobAsCommitted() {
        let sut = makeSUT()
        sut.record(makeKey("upload-1"))

        sut.attachFileID("file-77", toUploadID: "upload-1")

        XCTAssertEqual(sut.key(forUploadID: "upload-1")?.fileID, "file-77")
    }

    func test_attachFileID_isANoOpForAnUploadWithNoRecord() {
        let sut = makeSUT()
        sut.attachFileID("file-77", toUploadID: "never-recorded")

        XCTAssertTrue(sut.all().isEmpty)
    }

    func test_remove_dropsTheRecord() {
        let sut = makeSUT()
        sut.record(makeKey("upload-1"))

        sut.remove(uploadID: "upload-1")

        XCTAssertNil(sut.key(forUploadID: "upload-1"))
    }

    // MARK: - Listing

    func test_all_returnsRecordsOldestFirst() {
        let sut = makeSUT()
        sut.record(makeKey("newer", createdAt: Date(timeIntervalSince1970: 2_000)))
        sut.record(makeKey("older", createdAt: Date(timeIntervalSince1970: 1_000)))

        XCTAssertEqual(sut.all().map(\.uploadID), ["older", "newer"])
    }

    func test_all_isEmptyForAStoreThatHasNeverBeenWritten() {
        XCTAssertTrue(makeSUT().all().isEmpty)
    }

    // MARK: - Pruning

    func test_pruneAbandoned_dropsAnOldRecordThatNeverGotAFileID() {
        let sut = makeSUT()
        let long = PendingUploadKeyStore.abandonedRecordTTL
        sut.record(makeKey("stale", createdAt: Date(timeIntervalSince1970: 0)))

        let pruned = sut.pruneAbandoned(olderThan: long,
                                        now: Date(timeIntervalSince1970: long + 1))

        XCTAssertEqual(pruned, 1)
        XCTAssertTrue(sut.all().isEmpty)
    }

    /// A record with a file id is the only thing standing between a committed blob and a
    /// permanently unreadable file. Age is not a reason to throw it away.
    func test_pruneAbandoned_keepsAnOldRecordThatHasAFileID() {
        let sut = makeSUT()
        let long = PendingUploadKeyStore.abandonedRecordTTL
        sut.record(makeKey("committed", fileID: "file-77", createdAt: Date(timeIntervalSince1970: 0)))

        let pruned = sut.pruneAbandoned(olderThan: long,
                                        now: Date(timeIntervalSince1970: long * 10))

        XCTAssertEqual(pruned, 0)
        XCTAssertEqual(sut.all().map(\.uploadID), ["committed"])
    }

    func test_pruneAbandoned_keepsARecentRecordWithNoFileID() {
        let sut = makeSUT()
        sut.record(makeKey("fresh", createdAt: Date(timeIntervalSince1970: 1_000)))

        let pruned = sut.pruneAbandoned(olderThan: 3_600, now: Date(timeIntervalSince1970: 1_060))

        XCTAssertEqual(pruned, 0)
        XCTAssertEqual(sut.all().count, 1)
    }

    // MARK: - Transfer identity

    /// `BackgroundTransferService.claimOrphanedResult` is keyed on this. It used to default to
    /// a fresh `UUID()` per attempt, so a retry could never match a transfer that finished
    /// while the app was suspended — the orphan-claim path was unreachable from uploads.
    func test_blobTransferID_isStableForTheSameUpload() {
        XCTAssertEqual(E2EEUploader.blobTransferID(uploadID: "photo-sync:asset-1"),
                       E2EEUploader.blobTransferID(uploadID: "photo-sync:asset-1"))
    }

    func test_blobTransferID_differsBetweenUploads() {
        XCTAssertNotEqual(E2EEUploader.blobTransferID(uploadID: "a"),
                          E2EEUploader.blobTransferID(uploadID: "b"))
    }

    func test_photoSyncUploadID_isDerivedFromTheAssetIdentifier() {
        XCTAssertEqual(PhotoSyncService.uploadID(forAssetIdentifier: "ABC-123/L0/001"),
                       "photo-sync:ABC-123/L0/001")
    }
}
