import XCTest
@testable import NeutrinoDrive

/// Unit tests for DriveItem helper properties.
///
/// These assert the item-level wiring — that `DriveItem` hands the right three inputs to
/// `FileKind.classify` and surfaces its answer. The classifier's own edge cases live in
/// `FileKindTests`.
final class DriveItemTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(type: DriveItem.ItemType,
                          mimeType: String?,
                          name: String = "Test Item") -> DriveItem {
        DriveItem(
            id: UUID().uuidString,
            name: name,
            type: type,
            parentID: nil,
            size: type == .file ? 1024 : nil,
            modifiedAt: Date(),
            isTrashed: false,
            isShared: false,
            mimeType: mimeType
        )
    }

    // MARK: - kind: Folder

    func test_kind_folderType_isFolder() {
        let item = makeItem(type: .folder, mimeType: nil)
        XCTAssertEqual(item.kind, .folder)
        XCTAssertEqual(item.iconName, "folder.fill")
    }

    /// A folder is a folder even if the server sends a MIME type for it.
    func test_kind_folderType_ignoresMimeType() {
        let item = makeItem(type: .folder, mimeType: "image/jpeg")
        XCTAssertEqual(item.kind, .folder)
    }

    // MARK: - kind: Neutrino native formats

    func test_kind_neutrinoDoc() {
        XCTAssertEqual(makeItem(type: .file, mimeType: NeutrinoMIME.doc).kind, .neutrinoDoc)
    }

    func test_kind_neutrinoSheet() {
        XCTAssertEqual(makeItem(type: .file, mimeType: NeutrinoMIME.sheet).kind, .neutrinoSheet)
    }

    func test_kind_neutrinoSlide() {
        XCTAssertEqual(makeItem(type: .file, mimeType: NeutrinoMIME.slide).kind, .neutrinoSlide)
    }

    func test_kind_neutrinoDiagram() {
        XCTAssertEqual(makeItem(type: .file, mimeType: NeutrinoMIME.diagram).kind, .neutrinoDiagram)
    }

    func test_kind_neutrinoDrawing() {
        XCTAssertEqual(makeItem(type: .file, mimeType: NeutrinoMIME.drawing).kind, .neutrinoDrawing)
    }

    func test_kind_neutrinoNote() {
        XCTAssertEqual(makeItem(type: .file, mimeType: NeutrinoMIME.note).kind, .neutrinoNote)
    }

    /// The regression this whole change exists for: the app previously matched
    /// `application/vnd.neutrino.*`, a spelling the server never sends, so every native
    /// document was classified as a nondescript file and drew the default icon.
    func test_kind_everyNeutrinoNativeMime_isRecognised() {
        let natives = [NeutrinoMIME.doc, NeutrinoMIME.sheet, NeutrinoMIME.slide,
                       NeutrinoMIME.diagram, NeutrinoMIME.drawing, NeutrinoMIME.note]
        for mime in natives {
            let item = makeItem(type: .file, mimeType: mime)
            XCTAssertNotEqual(item.kind, .unknown, "\(mime) fell through to the default icon")
            XCTAssertTrue(item.isNeutrinoNativeFormat, "\(mime) is not reported as native")
            XCTAssertNotNil(item.kind.assetName, "\(mime) has no custom Neutrino icon")
        }
    }

    func test_isNeutrinoNativeFormat_ordinaryFile_isFalse() {
        XCTAssertFalse(makeItem(type: .file, mimeType: "application/pdf").isNeutrinoNativeFormat)
    }

    func test_isNeutrinoNativeFormat_nilMimeType_isFalse() {
        XCTAssertFalse(makeItem(type: .file, mimeType: nil).isNeutrinoNativeFormat)
    }

    // MARK: - kind: Ordinary types

    func test_kind_imageMimeTypes() {
        XCTAssertEqual(makeItem(type: .file, mimeType: "image/jpeg").kind, .image)
        XCTAssertEqual(makeItem(type: .file, mimeType: "image/png").kind, .image)
    }

    func test_kind_pdfMimeType() {
        XCTAssertEqual(makeItem(type: .file, mimeType: "application/pdf").kind, .pdf)
    }

    func test_kind_videoMimeTypes() {
        XCTAssertEqual(makeItem(type: .file, mimeType: "video/mp4").kind, .video)
        XCTAssertEqual(makeItem(type: .file, mimeType: "video/quicktime").kind, .video)
    }

    func test_kind_audioMimeType() {
        XCTAssertEqual(makeItem(type: .file, mimeType: "audio/mpeg").kind, .audio)
    }

    func test_kind_archiveMimeType() {
        XCTAssertEqual(makeItem(type: .file, mimeType: "application/zip").kind, .archive)
    }

    func test_kind_textMimeType() {
        XCTAssertEqual(makeItem(type: .file, mimeType: "text/plain").kind, .text)
    }

    func test_kind_htmlMimeType_isCode() {
        XCTAssertEqual(makeItem(type: .file, mimeType: "text/html").kind, .code)
    }

    // MARK: - kind: Unknown

    func test_kind_nilMimeTypeAndNoExtension_isUnknown() {
        let item = makeItem(type: .file, mimeType: nil)
        XCTAssertEqual(item.kind, .unknown)
        XCTAssertEqual(item.iconName, "doc.fill")
    }

    /// `UploadService` sends `application/octet-stream` whenever `UTType` cannot resolve the
    /// source file, and the server stores what it is sent — so the filename has to be able to
    /// rescue the icon.
    func test_kind_octetStreamMimeType_fallsBackToFilenameExtension() {
        let item = makeItem(type: .file, mimeType: "application/octet-stream", name: "Contract.docx")
        XCTAssertEqual(item.kind, .document)
    }

    func test_kind_octetStreamMimeTypeAndNoExtension_isUnknown() {
        let item = makeItem(type: .file, mimeType: "application/octet-stream", name: "blob")
        XCTAssertEqual(item.kind, .unknown)
    }
}
