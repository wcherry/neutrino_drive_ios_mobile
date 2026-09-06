import XCTest
import NeutrinoCore
@testable import NeutrinoDrive

/// Tests for the Universal Link format shared by Drive, Notes, and Docs.
///
/// These assertions are a contract between three separately shipped binaries: an app built last
/// month must still open a link minted today. Changing an expectation here means changing the
/// matching test in `neutrino_notes_ios_mobile` and `neutrino_docs_ios_mobile` too, and re-checking
/// `deploy/apple-app-site-association`.
final class NeutrinoAppLinkTests: XCTestCase {

    // MARK: - Building

    func test_url_buildsCanonicalNoteLink() {
        let url = NeutrinoAppLink.url(kind: .note, fileID: "0d0f7c")
        XCTAssertEqual(url?.absoluteString, "https://www.getneutrino.app/open/note/0d0f7c")
    }

    func test_url_buildsCanonicalDocLink() {
        let url = NeutrinoAppLink.url(kind: .doc, fileID: "abc123")
        XCTAssertEqual(url?.absoluteString, "https://www.getneutrino.app/open/doc/abc123")
    }

    func test_url_includesContentVersionWhenSupplied() {
        let url = NeutrinoAppLink.url(kind: .note, fileID: "f1", contentVersion: 42)
        XCTAssertEqual(url?.absoluteString, "https://www.getneutrino.app/open/note/f1?v=42")
    }

    func test_url_omitsVersionQueryWhenNil() {
        let url = NeutrinoAppLink.url(kind: .note, fileID: "f1")
        XCTAssertFalse(url?.absoluteString.contains("?") ?? true)
    }

    func test_url_returnsNilForEmptyFileID() {
        XCTAssertNil(NeutrinoAppLink.url(kind: .note, fileID: ""))
    }

    func test_url_returnsNilForWhitespaceOnlyFileID() {
        XCTAssertNil(NeutrinoAppLink.url(kind: .note, fileID: "   "))
    }

    func test_urlForMIME_routesNoteMIMEToNotes() {
        let url = NeutrinoAppLink.url(forFileID: "f1", mimeType: "application/x-neutrino-note")
        XCTAssertEqual(url?.path, "/open/note/f1")
    }

    func test_urlForMIME_returnsNilForUnclaimedType() {
        XCTAssertNil(NeutrinoAppLink.url(forFileID: "f1", mimeType: "image/jpeg"))
    }

    // MARK: - Round trip

    func test_destination_roundTripsEveryKind() {
        for kind in NeutrinoAppLink.Kind.allCases {
            let url = NeutrinoAppLink.url(kind: kind, fileID: "file-\(kind.rawValue)")
            let parsed = url.flatMap { NeutrinoAppLink.destination(from: $0) }
            XCTAssertEqual(parsed?.kind, kind, "round trip failed for \(kind.rawValue)")
            XCTAssertEqual(parsed?.fileID, "file-\(kind.rawValue)")
        }
    }

    func test_destination_roundTripsContentVersion() {
        let url = NeutrinoAppLink.url(kind: .doc, fileID: "f1", contentVersion: 7)!
        XCTAssertEqual(NeutrinoAppLink.destination(from: url)?.contentVersion, 7)
    }

    // MARK: - Parsing

    func test_destination_parsesFileID() {
        let url = URL(string: "https://www.getneutrino.app/open/note/0d0f7c")!
        XCTAssertEqual(NeutrinoAppLink.destination(from: url)?.fileID, "0d0f7c")
    }

    func test_destination_acceptsApexHost() {
        let url = URL(string: "https://getneutrino.app/open/doc/f1")!
        XCTAssertEqual(NeutrinoAppLink.destination(from: url)?.kind, .doc)
    }

    func test_destination_isCaseInsensitiveOnHost() {
        let url = URL(string: "https://WWW.GetNeutrino.app/open/note/f1")!
        XCTAssertNotNil(NeutrinoAppLink.destination(from: url))
    }

    func test_destination_rejectsForeignHost() {
        let url = URL(string: "https://evil.example.com/open/note/f1")!
        XCTAssertNil(NeutrinoAppLink.destination(from: url))
    }

    /// A lookalike host must not match by suffix: `getneutrino.app.evil.com` is somebody else's.
    func test_destination_rejectsSuffixLookalikeHost() {
        let url = URL(string: "https://www.getneutrino.app.evil.com/open/note/f1")!
        XCTAssertNil(NeutrinoAppLink.destination(from: url))
    }

    func test_destination_rejectsPlainHTTP() {
        let url = URL(string: "http://www.getneutrino.app/open/note/f1")!
        XCTAssertNil(NeutrinoAppLink.destination(from: url))
    }

    func test_destination_rejectsCustomScheme() {
        let url = URL(string: "neutrinonotes://open/note/f1")!
        XCTAssertNil(NeutrinoAppLink.destination(from: url))
    }

    func test_destination_rejectsUnknownKind() {
        let url = URL(string: "https://www.getneutrino.app/open/spreadsheet/f1")!
        XCTAssertNil(NeutrinoAppLink.destination(from: url))
    }

    func test_destination_rejectsWrongPathPrefix() {
        let url = URL(string: "https://www.getneutrino.app/files/note/f1")!
        XCTAssertNil(NeutrinoAppLink.destination(from: url))
    }

    func test_destination_rejectsMissingFileID() {
        let url = URL(string: "https://www.getneutrino.app/open/note")!
        XCTAssertNil(NeutrinoAppLink.destination(from: url))
    }

    func test_destination_rejectsExtraPathSegments() {
        let url = URL(string: "https://www.getneutrino.app/open/note/f1/versions/3")!
        XCTAssertNil(NeutrinoAppLink.destination(from: url))
    }

    func test_destination_ignoresUnparseableVersion() {
        let url = URL(string: "https://www.getneutrino.app/open/note/f1?v=latest")!
        let parsed = NeutrinoAppLink.destination(from: url)
        XCTAssertEqual(parsed?.fileID, "f1")
        XCTAssertNil(parsed?.contentVersion)
    }

    // MARK: - MIME routing

    func test_kindForMIME_routesServerNoteType() {
        XCTAssertEqual(NeutrinoAppLink.kind(forMIME: "application/x-neutrino-note"), .note)
    }

    func test_kindForMIME_routesServerDocType() {
        XCTAssertEqual(NeutrinoAppLink.kind(forMIME: "application/x-neutrino-doc"), .doc)
    }

    /// Older records carry the `vnd.` spelling that `DriveItem.NeutrinoMIME` still uses.
    func test_kindForMIME_routesLegacyVndSpelling() {
        XCTAssertEqual(NeutrinoAppLink.kind(forMIME: "application/vnd.neutrino.doc"), .doc)
    }

    func test_kindForMIME_ignoresParameters() {
        XCTAssertEqual(NeutrinoAppLink.kind(forMIME: "application/x-neutrino-note; charset=utf-8"), .note)
    }

    func test_kindForMIME_isCaseInsensitive() {
        XCTAssertEqual(NeutrinoAppLink.kind(forMIME: "APPLICATION/X-NEUTRINO-NOTE"), .note)
    }

    // MARK: - MIME routing: OOXML

    /// A Neutrino document *is* a `.docx` (issue #127), so an Office file in Drive routes to the
    /// editor that owns it rather than down the download-and-Quick-Look path.
    func test_kindForMIME_routesDocxToDocs() {
        XCTAssertEqual(NeutrinoAppLink.kind(forMIME: NeutrinoAppLink.OOXML.docx), .doc)
    }

    func test_kindForMIME_routesXlsxToSheets() {
        XCTAssertEqual(NeutrinoAppLink.kind(forMIME: NeutrinoAppLink.OOXML.xlsx), .sheet)
    }

    func test_kindForMIME_routesPptxToSlides() {
        XCTAssertEqual(NeutrinoAppLink.kind(forMIME: NeutrinoAppLink.OOXML.pptx), .slide)
    }

    /// Pins the exact wire strings: these are matched against what the backend wrote, so a typo
    /// here would silently stop routing every Office file rather than fail to compile.
    func test_ooxmlTypes_matchTheServersSpelling() {
        XCTAssertEqual(NeutrinoAppLink.OOXML.docx,
                       "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertEqual(NeutrinoAppLink.OOXML.xlsx,
                       "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertEqual(NeutrinoAppLink.OOXML.pptx,
                       "application/vnd.openxmlformats-officedocument.presentationml.presentation")
    }

    /// The pre-OOXML Office formats are foreign files Neutrino cannot open. Routing one to an
    /// editor that would fail to parse it is worse than the download it gets today.
    func test_kindForMIME_doesNotClaimLegacyOfficeTypes() {
        XCTAssertNil(NeutrinoAppLink.kind(forMIME: "application/msword"))
        XCTAssertNil(NeutrinoAppLink.kind(forMIME: "application/vnd.ms-excel"))
        XCTAssertNil(NeutrinoAppLink.kind(forMIME: "application/vnd.ms-powerpoint"))
    }

    func test_kindForMIME_returnsNilForOrdinaryFile() {
        XCTAssertNil(NeutrinoAppLink.kind(forMIME: "application/pdf"))
    }

    func test_kindForMIME_returnsNilForNilType() {
        XCTAssertNil(NeutrinoAppLink.kind(forMIME: nil))
    }

    /// `.file` means "Drive itself", which is a property of the link and never of a MIME type.
    func test_kindForMIME_neverReturnsFile() {
        for kind in NeutrinoAppLink.Kind.allCases where kind != .file {
            for mime in kind.mimeTypes {
                XCTAssertNotEqual(NeutrinoAppLink.kind(forMIME: mime), .file)
            }
        }
    }

    func test_mimeTypes_areUniqueAcrossKinds() {
        var seen: Set<String> = []
        for kind in NeutrinoAppLink.Kind.allCases {
            for mime in kind.mimeTypes {
                XCTAssertFalse(seen.contains(mime), "\(mime) is claimed by more than one kind")
                seen.insert(mime)
            }
        }
    }

    // MARK: - Companion apps

    /// Every format an iOS app exists (or is being built) for is offered. Sheets and Slides are
    /// included ahead of their releases on purpose: a miss falls through to the Drive viewer, which
    /// is what tapping the file did anyway, and the route needs no change when they ship.
    func test_hasCompanionApp_isTrueForEveryEditorApp() {
        XCTAssertTrue(NeutrinoAppLink.Kind.note.hasCompanionApp)
        XCTAssertTrue(NeutrinoAppLink.Kind.doc.hasCompanionApp)
        XCTAssertTrue(NeutrinoAppLink.Kind.sheet.hasCompanionApp)
        XCTAssertTrue(NeutrinoAppLink.Kind.slide.hasCompanionApp)
    }

    /// Diagrams and Drawings are web-only, and `.file` means Drive itself.
    func test_hasCompanionApp_isFalseWhereNoIOSAppExists() {
        XCTAssertFalse(NeutrinoAppLink.Kind.diagram.hasCompanionApp)
        XCTAssertFalse(NeutrinoAppLink.Kind.drawing.hasCompanionApp)
        XCTAssertFalse(NeutrinoAppLink.Kind.file.hasCompanionApp)
    }

    /// The three Office formats the user can tap must each reach an app, or the hand-off this all
    /// exists for silently does nothing for the file types it was built around.
    func test_hasCompanionApp_coversEveryOOXMLFormat() {
        for mime in [NeutrinoAppLink.OOXML.docx,
                     NeutrinoAppLink.OOXML.xlsx,
                     NeutrinoAppLink.OOXML.pptx] {
            let kind = NeutrinoAppLink.kind(forMIME: mime)
            XCTAssertNotNil(kind, "\(mime) routes nowhere")
            XCTAssertEqual(kind?.hasCompanionApp, true, "\(mime) is not offered a companion app")
        }
    }
}
