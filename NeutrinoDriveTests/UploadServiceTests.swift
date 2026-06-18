import XCTest
@testable import NeutrinoDrive

/// Unit tests for UploadService and DriveService.fileWasUploaded.
/// Network calls are not made — tests exercise the synchronous/in-process paths only.
@MainActor
final class UploadServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeUploadResult(
        id: String = "file-1",
        name: String = "test.txt",
        folderId: String? = nil,
        sizeBytes: Int64 = 512,
        mimeType: String = "text/plain"
    ) -> UploadResult {
        UploadResult(id: id, name: name, folderId: folderId,
                     sizeBytes: sizeBytes, mimeType: mimeType, updatedAt: Date())
    }

    // MARK: - UploadService initial state

    func test_initialState_isNotUploading() {
        let sut = UploadService()
        XCTAssertFalse(sut.isUploading)
    }

    func test_initialState_progressIsZero() {
        let sut = UploadService()
        XCTAssertEqual(sut.progress, 0)
    }

    func test_initialState_errorIsNil() {
        let sut = UploadService()
        XCTAssertNil(sut.error)
    }

    // MARK: - upload — pre-condition errors

    func test_upload_throwsNoEncryptionKey_whenKeysAbsent() async {
        // Make sure no keys are stored in the test keychain slot.
        KeychainService.delete(forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.delete(forKey: KeyImportService.privateKeyKeychainKey)

        let sut = UploadService()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? "hello".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await sut.upload(fileURL: tempURL, parentFolderID: nil)
            XCTFail("Expected UploadError.noEncryptionKey")
        } catch let err as UploadError {
            if case .noEncryptionKey = err { /* expected */ } else {
                XCTFail("Unexpected error: \(err)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - DriveService.fileWasUploaded

    func test_fileWasUploaded_addsItemToAllItems() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u1", name: "photo.jpg")

        sut.fileWasUploaded(result)

        XCTAssertTrue(sut.allItems.contains(where: { $0.id == "u1" }))
    }

    func test_fileWasUploaded_itemHasCorrectName() {
        let sut = DriveService()
        let result = makeUploadResult(name: "document.pdf")

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.name == "document.pdf" })?.name, "document.pdf")
    }

    func test_fileWasUploaded_itemTypeIsFile() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u2")

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "u2" })?.type, .file)
    }

    func test_fileWasUploaded_itemHasCorrectParentID() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u3", folderId: "parent-folder")

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "u3" })?.parentID, "parent-folder")
    }

    func test_fileWasUploaded_itemNotTrashed() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u4")

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "u4" })?.isTrashed, false)
    }

    func test_fileWasUploaded_itemHasCorrectSize() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u5", sizeBytes: 4096)

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "u5" })?.size, 4096)
    }

    func test_fileWasUploaded_itemHasCorrectMimeType() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u6", mimeType: "image/jpeg")

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "u6" })?.mimeType, "image/jpeg")
    }

    func test_fileWasUploaded_appearsInMyDriveSection_whenNoParent() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u7", folderId: nil)

        sut.fileWasUploaded(result)

        let visible = sut.items(in: .myDrive, parentID: nil)
        XCTAssertTrue(visible.contains(where: { $0.id == "u7" }))
    }

    func test_fileWasUploaded_appearsInSubfolder_whenParentSet() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u8", folderId: "folder-abc")

        sut.fileWasUploaded(result)

        let visible = sut.items(in: .myDrive, parentID: "folder-abc")
        XCTAssertTrue(visible.contains(where: { $0.id == "u8" }))
    }

    func test_fileWasUploaded_multipleUploads_allAppear() {
        let sut = DriveService()
        let r1 = makeUploadResult(id: "a", name: "a.txt")
        let r2 = makeUploadResult(id: "b", name: "b.txt")

        sut.fileWasUploaded(r1)
        sut.fileWasUploaded(r2)

        XCTAssertTrue(sut.allItems.contains(where: { $0.id == "a" }))
        XCTAssertTrue(sut.allItems.contains(where: { $0.id == "b" }))
    }
}
