import XCTest
import NeutrinoCore
import NeutrinoCrypto
@testable import NeutrinoDrive

/// Unit tests for OfflineService and the OfflineFile model.
/// Network calls are not made — tests exercise the synchronous/in-process paths only.
///
/// OfflineService persists a manifest under the app's real Application Support directory in
/// production. To keep these tests from touching (or leaking state into) that real directory,
/// every instance under test here is constructed via the `#if DEBUG` seed initializer with an
/// explicit, test-owned `storageDirectory` — a fresh temp directory created per test and
/// removed in a `defer`. This mirrors DriveService's own `#if DEBUG convenience init(myDrive:
/// trash: recents: shared:)` seam, extended with a `storageDirectory` parameter since
/// OfflineService (unlike DriveService) touches disk.
@MainActor
final class OfflineServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeOfflineFile(
        id: String,
        name: String = "doc.pdf",
        mimeType: String = "application/pdf",
        sizeBytes: Int64 = 1024,
        localURL: URL = URL(fileURLWithPath: "/tmp/placeholder"),
        cachedAt: Date = Date()
    ) -> OfflineFile {
        OfflineFile(id: id, name: name, mimeType: mimeType, sizeBytes: sizeBytes,
                    localURL: localURL, cachedAt: cachedAt)
    }

    // MARK: - OfflineService initial state

    func test_initialState_offlineFilesIsEmpty() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sut = OfflineService(storageDirectory: tempDir)

        XCTAssertTrue(sut.offlineFiles.isEmpty)
    }

    // MARK: - isOffline(fileID:)

    func test_isOffline_seededFileID_returnsTrue() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let seeded = makeOfflineFile(id: "f1")
        let sut = OfflineService(offlineFiles: [seeded], storageDirectory: tempDir)

        XCTAssertTrue(sut.isOffline(fileID: "f1"))
    }

    func test_isOffline_unknownFileID_returnsFalse() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let seeded = makeOfflineFile(id: "f1")
        let sut = OfflineService(offlineFiles: [seeded], storageDirectory: tempDir)

        XCTAssertFalse(sut.isOffline(fileID: "does-not-exist"))
    }

    func test_isOffline_emptyState_returnsFalse() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sut = OfflineService(storageDirectory: tempDir)

        XCTAssertFalse(sut.isOffline(fileID: "anything"))
    }

    // MARK: - cacheSizeBytes()

    func test_cacheSizeBytes_emptyState_returnsZero() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sut = OfflineService(storageDirectory: tempDir)

        XCTAssertEqual(sut.cacheSizeBytes(), 0)
    }

    func test_cacheSizeBytes_sumsSeededEntries() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let seeded = [
            makeOfflineFile(id: "f1", sizeBytes: 1000),
            makeOfflineFile(id: "f2", sizeBytes: 2500),
            makeOfflineFile(id: "f3", sizeBytes: 42),
        ]
        let sut = OfflineService(offlineFiles: seeded, storageDirectory: tempDir)

        XCTAssertEqual(sut.cacheSizeBytes(), 3542)
    }

    func test_cacheSizeBytes_singleZeroSizedEntry_returnsZero() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let seeded = [makeOfflineFile(id: "f1", sizeBytes: 0)]
        let sut = OfflineService(offlineFiles: seeded, storageDirectory: tempDir)

        XCTAssertEqual(sut.cacheSizeBytes(), 0)
    }

    // MARK: - removeOffline(fileID:)

    func test_removeOffline_removesMatchingEntryFromOfflineFiles() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("keep.txt")
        try? "offline content".write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = makeOfflineFile(id: "f1", name: "keep.txt", sizeBytes: 15, localURL: fileURL)
        let sut = OfflineService(offlineFiles: [entry], storageDirectory: tempDir)

        sut.removeOffline(fileID: "f1")

        XCTAssertFalse(sut.offlineFiles.contains(where: { $0.id == "f1" }))
    }

    func test_removeOffline_leavesOtherEntriesIntact() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL1 = tempDir.appendingPathComponent("a.txt")
        let fileURL2 = tempDir.appendingPathComponent("b.txt")
        try? "a".write(to: fileURL1, atomically: true, encoding: .utf8)
        try? "b".write(to: fileURL2, atomically: true, encoding: .utf8)

        let entries = [
            makeOfflineFile(id: "f1", name: "a.txt", localURL: fileURL1),
            makeOfflineFile(id: "f2", name: "b.txt", localURL: fileURL2),
        ]
        let sut = OfflineService(offlineFiles: entries, storageDirectory: tempDir)

        sut.removeOffline(fileID: "f1")

        XCTAssertTrue(sut.offlineFiles.contains(where: { $0.id == "f2" }))
    }

    func test_removeOffline_unknownFileID_doesNothing() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entry = makeOfflineFile(id: "f1")
        let sut = OfflineService(offlineFiles: [entry], storageDirectory: tempDir)

        sut.removeOffline(fileID: "ghost")

        XCTAssertEqual(sut.offlineFiles.count, 1)
        XCTAssertTrue(sut.offlineFiles.contains(where: { $0.id == "f1" }))
    }

    // MARK: - makeAvailableOffline — pre-condition errors (no network reached)
    //
    // DownloadService.download(fileID:fileName:mimeType:) checks for stored encryption keys
    // before any network call is made (see DownloadServiceTests.test_download_throwsNoEncryptionKey_whenKeysAbsent).
    // Since makeAvailableOffline delegates to DownloadService.download, this same pre-condition
    // check fires before OfflineService touches the network, making it safe to test here.

    func test_makeAvailableOffline_throws_whenDownloadServiceHasNoEncryptionKey() async {
        KeychainService.delete(forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.delete(forKey: KeyImportService.privateKeyKeychainKey)

        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sut = OfflineService(storageDirectory: tempDir)
        let downloadService = DownloadService()
        let item = DriveItem(id: "f1", name: "doc.pdf", type: .file, parentID: nil, size: 100,
                             modifiedAt: Date(), isTrashed: false, isShared: false,
                             mimeType: "application/pdf")

        do {
            try await sut.makeAvailableOffline(item: item, downloadService: downloadService)
            XCTFail("Expected an error when no encryption key is available")
        } catch {
            // OfflineService may propagate DownloadError directly or wrap it in its own
            // OfflineError — the plan doesn't pin down which, so only the throw itself,
            // and the fact that no entry is recorded, are asserted.
        }
    }

    func test_makeAvailableOffline_doesNotAddEntry_whenDownloadServiceHasNoEncryptionKey() async {
        KeychainService.delete(forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.delete(forKey: KeyImportService.privateKeyKeychainKey)

        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sut = OfflineService(storageDirectory: tempDir)
        let downloadService = DownloadService()
        let item = DriveItem(id: "f1", name: "doc.pdf", type: .file, parentID: nil, size: 100,
                             modifiedAt: Date(), isTrashed: false, isShared: false,
                             mimeType: "application/pdf")

        _ = try? await sut.makeAvailableOffline(item: item, downloadService: downloadService)

        XCTAssertTrue(sut.offlineFiles.isEmpty)
    }

    // MARK: - OfflineFile Codable round-trip

    func test_offlineFile_codableRoundTrip_preservesFields() throws {
        let original = OfflineFile(
            id: "f1",
            name: "report.pdf",
            mimeType: "application/pdf",
            sizeBytes: 2048,
            localURL: URL(fileURLWithPath: "/tmp/f1/report.pdf"),
            cachedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OfflineFile.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.mimeType, original.mimeType)
        XCTAssertEqual(decoded.sizeBytes, original.sizeBytes)
        XCTAssertEqual(decoded.cachedAt, original.cachedAt)
        // localURL is deliberately not asserted here: the plan states it is "stored as a
        // relative path, resolved against the offline directory at read time," which is an
        // internal representation detail this test should not pin down. Encode→decode symmetry
        // of the other fields is what's under test.
    }
}
