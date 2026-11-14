import XCTest
import FileProvider
@testable import NeutrinoDrive

/// Unit tests for the Drive ID ⇄ `NSFileProviderItemIdentifier` mapping.
///
/// **Why this file exists at all.** A File Provider extension cannot be instantiated or driven
/// from a unit-test host — it is loaded by `fileproviderd` against a registered domain, in its
/// own process. So the strategy is to pull every piece of logic that could silently be wrong out
/// of the untestable shell and into types the app target also compiles. This mapping is the
/// clearest example: a collision between a file ID and a folder ID would produce no build error
/// and no request error, just the Files app occasionally acting on the wrong row.
///
/// See "What is actually testable" in
/// `agent_docs/plans/feature-phase3-ios-ecosystem-integration.md`.
final class FileProviderIdentifierTests: XCTestCase {

    // MARK: - Round trips

    func test_fileIdentifier_roundTripsToFileID() {
        let identifier = FileProviderIdentifier.forFile("abc-123")
        XCTAssertEqual(FileProviderIdentifier.resolve(identifier), .file("abc-123"))
    }

    func test_folderIdentifier_roundTripsToFolderID() {
        let identifier = FileProviderIdentifier.forFolder("abc-123")
        XCTAssertEqual(FileProviderIdentifier.resolve(identifier), .folder("abc-123"))
    }

    /// The collision this whole prefixing scheme exists to prevent. File IDs and folder IDs come
    /// from two different backend tables and nothing guarantees they are disjoint.
    func test_fileAndFolder_withSameUnderlyingID_produceDistinctIdentifiers() {
        let sharedID = "collision"
        let fileIdentifier = FileProviderIdentifier.forFile(sharedID)
        let folderIdentifier = FileProviderIdentifier.forFolder(sharedID)

        XCTAssertNotEqual(fileIdentifier, folderIdentifier)
        XCTAssertEqual(FileProviderIdentifier.resolve(fileIdentifier), .file(sharedID))
        XCTAssertEqual(FileProviderIdentifier.resolve(folderIdentifier), .folder(sharedID))
    }

    // MARK: - Root

    func test_rootContainer_mapsToNilParentID() {
        XCTAssertEqual(FileProviderIdentifier.resolve(.rootContainer), .root)
    }

    /// The Drive root has no ID of its own — it is `parentID == nil` throughout the API — and the
    /// system reserves `.rootContainer`. An extension that mints its own root identifier shows an
    /// empty location in the Files app.
    func test_identifier_forNilParentID_isRootContainer() {
        XCTAssertEqual(FileProviderIdentifier.forFolder(nil), .rootContainer)
        XCTAssertEqual(FileProviderIdentifier.forParent(nil), .rootContainer)
    }

    func test_forParent_withFolderID_isFolderIdentifier() {
        XCTAssertEqual(FileProviderIdentifier.forParent("parent-1"),
                       FileProviderIdentifier.forFolder("parent-1"))
    }

    // MARK: - Rejection

    /// An identifier we did not mint means a bug somewhere. Treating it as a bare Drive ID would
    /// convert that bug into a request against an arbitrary row.
    func test_parse_returnsNil_forUnprefixedIdentifier() {
        XCTAssertNil(FileProviderIdentifier.resolve(NSFileProviderItemIdentifier("abc-123")))
    }

    func test_parse_returnsNil_forEmptyIdentifier() {
        XCTAssertNil(FileProviderIdentifier.resolve(NSFileProviderItemIdentifier("")))
    }

    func test_parse_returnsNil_forPrefixWithNoID() {
        XCTAssertNil(FileProviderIdentifier.resolve(NSFileProviderItemIdentifier("f:")))
        XCTAssertNil(FileProviderIdentifier.resolve(NSFileProviderItemIdentifier("d:")))
    }

    // MARK: - Container resolution

    func test_containerFolderID_forRoot_isNilFolderID() {
        // `.some(nil)` — "this is a container, and its Drive folder ID is nil (the root)".
        guard let folderID = ResolvedIdentifier.root.containerFolderID else {
            return XCTFail("root must be a container")
        }
        XCTAssertNil(folderID)
    }

    func test_containerFolderID_forFolder_isFolderID() {
        guard let folderID = ResolvedIdentifier.folder("f1").containerFolderID else {
            return XCTFail("folder must be a container")
        }
        XCTAssertEqual(folderID, "f1")
    }

    /// A file is not a container. Answering with an empty list instead would present a file as
    /// an empty folder in the Files app.
    func test_containerFolderID_forFile_isNil() {
        XCTAssertNil(ResolvedIdentifier.file("f1").containerFolderID)
    }
}
