import XCTest
import FileProvider
import UniformTypeIdentifiers
@testable import NeutrinoDrive

/// Unit tests for `FileProviderItem` and `FileProviderLimits` — the mapping from the backend's
/// wire records to what the Files app displays, and the materialization size ceiling.
///
/// Same rationale as `FileProviderIdentifierTests`: the extension itself cannot be driven from a
/// test host, so the logic is factored out to where it can be.
final class FileProviderItemTests: XCTestCase {

    // MARK: - Fixtures

    private func makeFile(id: String = "file-1",
                          name: String = "Report.pdf",
                          folderId: String? = "folder-1",
                          sizeBytes: Int64 = 2048,
                          mimeType: String = "application/pdf") -> DriveFileRecord {
        DriveFileRecord(id: id, name: name, folderId: folderId, sizeBytes: sizeBytes,
                        mimeType: mimeType, updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        isStarred: false)
    }

    private func makeFolder(id: String = "folder-1",
                            name: String = "Documents",
                            parentId: String? = nil) -> DriveFolderRecord {
        DriveFolderRecord(id: id, name: name, parentId: parentId,
                          updatedAt: Date(timeIntervalSince1970: 1_700_000_000), isStarred: false)
    }

    // MARK: - File mapping

    func test_item_fromFileResponse_mapsFilenameAndSize() {
        let item = FileProviderItem(file: makeFile(name: "Report.pdf", sizeBytes: 2048))

        XCTAssertEqual(item.filename, "Report.pdf")
        XCTAssertEqual(item.documentSize, NSNumber(value: 2048))
        XCTAssertEqual(item.itemIdentifier, FileProviderIdentifier.forFile("file-1"))
    }

    func test_item_fromFileResponse_mapsParentIdentifier() {
        let item = FileProviderItem(file: makeFile(folderId: "folder-9"))
        XCTAssertEqual(item.parentItemIdentifier, FileProviderIdentifier.forFolder("folder-9"))
    }

    /// A file at the drive root must report `.rootContainer` as its parent, not a synthesised ID.
    func test_item_atRoot_hasRootContainerParent() {
        let item = FileProviderItem(file: makeFile(folderId: nil))
        XCTAssertEqual(item.parentItemIdentifier, .rootContainer)
    }

    func test_item_file_isNotFolderContentType() {
        let item = FileProviderItem(file: makeFile(mimeType: "application/pdf"))
        XCTAssertEqual(item.contentType, .pdf)
        XCTAssertNotEqual(item.contentType, .folder)
    }

    func test_item_fromFileResponse_carriesModificationDate() {
        let item = FileProviderItem(file: makeFile())
        XCTAssertEqual(item.contentModificationDate, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Folder mapping

    func test_item_fromFolderResponse_hasFolderContentType() {
        let item = FileProviderItem(folder: makeFolder(name: "Documents"))

        XCTAssertEqual(item.contentType, .folder)
        XCTAssertEqual(item.filename, "Documents")
        XCTAssertEqual(item.itemIdentifier, FileProviderIdentifier.forFolder("folder-1"))
    }

    /// A folder that advertises a document size renders in the Files app as a zero-byte document
    /// rather than as a navigable container.
    func test_item_folder_hasNilDocumentSize() {
        XCTAssertNil(FileProviderItem(folder: makeFolder()).documentSize)
    }

    func test_item_folderAtRoot_hasRootContainerParent() {
        XCTAssertEqual(FileProviderItem(folder: makeFolder(parentId: nil)).parentItemIdentifier,
                       .rootContainer)
    }

    func test_root_isFolderNamedNeutrinoDrive() {
        let root = FileProviderItem.root()
        XCTAssertEqual(root.itemIdentifier, .rootContainer)
        XCTAssertEqual(root.contentType, .folder)
        XCTAssertEqual(root.filename, "Neutrino Drive")
    }

    // MARK: - Capabilities

    func test_capabilities_forFile_allowReadingAndDeleting() {
        let item = FileProviderItem(file: makeFile())
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertTrue(item.capabilities.contains(.allowsRenaming))
        XCTAssertTrue(item.capabilities.contains(.allowsReparenting))
        XCTAssertTrue(item.capabilities.contains(.allowsDeleting))
    }

    /// Advertising writability the backend cannot honour would let a user edit a document in
    /// Pages, watch it save, and lose the edit. There is no endpoint that replaces a file's
    /// ciphertext in place, so read-only is the honest capability set.
    ///
    /// Asserted for **files only**, deliberately. `.allowsAddingSubItems` and `.allowsWriting`
    /// are the same bit (both raw value `2`; the SDK header says so), so a folder that accepts
    /// new files necessarily reports `.allowsWriting`. Asserting otherwise for folders would be
    /// testing an impossibility rather than a decision — see `FileProviderItem.folderCapabilities`.
    func test_capabilities_omitWritingContent() {
        XCTAssertFalse(FileProviderItem(file: makeFile()).capabilities.contains(.allowsWriting))
    }

    /// Pins the aliasing itself, so the reason the assertion above is file-only stays visible
    /// rather than looking like an oversight.
    func test_allowsAddingSubItems_isTheSameBitAsAllowsWriting() {
        XCTAssertEqual(NSFileProviderItemCapabilities.allowsAddingSubItems,
                       NSFileProviderItemCapabilities.allowsWriting)
        XCTAssertEqual(NSFileProviderItemCapabilities.allowsContentEnumerating,
                       NSFileProviderItemCapabilities.allowsReading)
    }

    func test_capabilities_forFolder_allowEnumeratingAndAddingSubItems() {
        let item = FileProviderItem(folder: makeFolder())
        XCTAssertTrue(item.capabilities.contains(.allowsContentEnumerating))
        XCTAssertTrue(item.capabilities.contains(.allowsAddingSubItems))
    }

    // MARK: - Content type resolution

    /// `UTType(mimeType:)` returns a *dynamic* type rather than nil for an unregistered MIME
    /// type, so a naive non-nil check would let a useless `dyn.a…` shadow the far better answer
    /// available from the filename extension.
    func test_contentType_fallsBackToFilenameExtension_whenMIMEUnknown() {
        // Neutrino's own vnd.neutrino.* types are not registered with the system.
        let type = FileProviderItem.contentType(forMIME: "application/vnd.neutrino.doc",
                                                filename: "Notes.pdf")
        XCTAssertEqual(type, .pdf)
    }

    func test_contentType_neverReturnsADynamicType() {
        let type = FileProviderItem.contentType(forMIME: "application/vnd.neutrino.sheet",
                                                filename: "Budget.neutrinosheet")
        XCTAssertFalse(type.isDynamic, "a dyn.* type is useless to the Files app")
        XCTAssertEqual(type, .data)
    }

    func test_contentType_fallsBackToData_whenNothingResolves() {
        let type = FileProviderItem.contentType(forMIME: "application/vnd.neutrino.doc",
                                                filename: "Notes")
        XCTAssertEqual(type, .data)
    }

    // MARK: - Versioning

    /// `NSFileProviderItemVersion` compares tokens byte-for-byte. Two items modified in the same
    /// second must still version distinctly, which is why the ID is folded in.
    func test_versionToken_differsPerItem_atSameTimestamp() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNotEqual(FileProviderItem.versionToken(id: "a", date: date),
                          FileProviderItem.versionToken(id: "b", date: date))
    }

    func test_versionToken_differsAcrossModifications() {
        XCTAssertNotEqual(
            FileProviderItem.versionToken(id: "a", date: Date(timeIntervalSince1970: 1_700_000_000)),
            FileProviderItem.versionToken(id: "a", date: Date(timeIntervalSince1970: 1_700_000_001))
        )
    }

    // MARK: - Materialization ceiling

    func test_canMaterialize_isFalse_aboveCeiling() {
        XCTAssertFalse(FileProviderLimits.canMaterialize(
            sizeBytes: FileProviderLimits.maxMaterializableBytes + 1))
    }

    func test_canMaterialize_isTrue_atCeiling() {
        XCTAssertTrue(FileProviderLimits.canMaterialize(
            sizeBytes: FileProviderLimits.maxMaterializableBytes))
    }

    /// An unknown size is permitted here; the real ceiling is enforced again in
    /// `E2EEDownloader` against the actual transferred bytes, which cannot be stale.
    func test_canMaterialize_isTrue_forUnknownSize() {
        XCTAssertTrue(FileProviderLimits.canMaterialize(sizeBytes: nil))
    }

    func test_canMaterialize_isTrue_forSmallFile() {
        XCTAssertTrue(FileProviderLimits.canMaterialize(sizeBytes: 1024))
    }
}
