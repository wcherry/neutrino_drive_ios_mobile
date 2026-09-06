import XCTest
import NeutrinoCore
@testable import NeutrinoDrive

/// Unit tests for DriveItem helper properties.
final class DriveItemTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(type: DriveItem.ItemType, mimeType: String?) -> DriveItem {
        DriveItem(
            id: UUID().uuidString,
            name: "Test Item",
            type: type,
            parentID: nil,
            size: type == .file ? 1024 : nil,
            modifiedAt: Date(),
            isTrashed: false,
            isShared: false,
            mimeType: mimeType
        )
    }

    // MARK: - iconName: Office formats

    /// A `.docx` in Drive is a Neutrino document, so it gets the document icon rather than the
    /// generic page every unrecognised upload falls back to.
    func test_iconName_docxMimeType_returnsDocumentIcon() {
        let item = makeItem(type: .file, mimeType: NeutrinoAppLink.OOXML.docx)
        XCTAssertEqual(item.iconName, "doc.text.fill")
    }

    func test_iconName_xlsxMimeType_returnsSpreadsheetIcon() {
        let item = makeItem(type: .file, mimeType: NeutrinoAppLink.OOXML.xlsx)
        XCTAssertEqual(item.iconName, "tablecells")
    }

    func test_iconName_pptxMimeType_returnsPresentationIcon() {
        let item = makeItem(type: .file, mimeType: NeutrinoAppLink.OOXML.pptx)
        XCTAssertEqual(item.iconName, "rectangle.stack.fill")
    }

    /// The two vintages of the same format are the same thing to a user, so they look the same.
    func test_iconName_matchesAcrossFormatGenerations() {
        for (modern, legacy) in [(NeutrinoAppLink.OOXML.docx, "application/x-neutrino-doc"),
                                 (NeutrinoAppLink.OOXML.xlsx, "application/x-neutrino-sheet"),
                                 (NeutrinoAppLink.OOXML.pptx, "application/x-neutrino-slide")] {
            XCTAssertEqual(makeItem(type: .file, mimeType: modern).iconName,
                           makeItem(type: .file, mimeType: legacy).iconName,
                           "\(modern) and \(legacy) show different icons")
        }
    }

    // MARK: - isNeutrinoNativeFormat

    /// This is what decides whether "Open in Drive" reaches the editor or downloads the bytes, so
    /// it has to recognise all three spellings the server has written over time.
    func test_isNeutrinoNativeFormat_acceptsEveryFormatGeneration() {
        for mime in [NeutrinoAppLink.OOXML.docx,
                     NeutrinoAppLink.OOXML.xlsx,
                     NeutrinoAppLink.OOXML.pptx,
                     "application/x-neutrino-doc",
                     "application/vnd.neutrino.doc"] {
            XCTAssertTrue(makeItem(type: .file, mimeType: mime).isNeutrinoNativeFormat,
                          "\(mime) was not recognised as a Neutrino file")
        }
    }

    func test_isNeutrinoNativeFormat_rejectsOrdinaryUploads() {
        XCTAssertFalse(makeItem(type: .file, mimeType: "application/pdf").isNeutrinoNativeFormat)
        XCTAssertFalse(makeItem(type: .file, mimeType: "image/jpeg").isNeutrinoNativeFormat)
        XCTAssertFalse(makeItem(type: .file, mimeType: nil).isNeutrinoNativeFormat)
    }

    /// A pre-OOXML Word file is a foreign upload Neutrino cannot edit — it must keep the download
    /// path rather than be handed to an editor that would fail to parse it.
    func test_isNeutrinoNativeFormat_rejectsLegacyOfficeFormats() {
        XCTAssertFalse(makeItem(type: .file, mimeType: "application/msword").isNeutrinoNativeFormat)
        XCTAssertFalse(makeItem(type: .file, mimeType: "application/vnd.ms-excel").isNeutrinoNativeFormat)
    }

    // MARK: - iconName: Folder

    func test_iconName_folderType_returnsFolderFill() {
        let item = makeItem(type: .folder, mimeType: nil)
        XCTAssertEqual(item.iconName, "folder.fill")
    }

    // MARK: - iconName: Image

    func test_iconName_imageJpegMimeType_returnsPhoto() {
        let item = makeItem(type: .file, mimeType: "image/jpeg")
        XCTAssertEqual(item.iconName, "photo")
    }

    func test_iconName_imagePngMimeType_returnsPhoto() {
        let item = makeItem(type: .file, mimeType: "image/png")
        XCTAssertEqual(item.iconName, "photo")
    }

    // MARK: - iconName: PDF

    func test_iconName_pdfMimeType_returnsDocRichtext() {
        let item = makeItem(type: .file, mimeType: "application/pdf")
        XCTAssertEqual(item.iconName, "doc.richtext")
    }

    // MARK: - iconName: Video

    func test_iconName_videoMp4MimeType_returnsFilm() {
        let item = makeItem(type: .file, mimeType: "video/mp4")
        XCTAssertEqual(item.iconName, "film")
    }

    func test_iconName_videoQuicktimeMimeType_returnsFilm() {
        let item = makeItem(type: .file, mimeType: "video/quicktime")
        XCTAssertEqual(item.iconName, "film")
    }

    // MARK: - iconName: Audio

    func test_iconName_audioMpegMimeType_returnsMusicNote() {
        let item = makeItem(type: .file, mimeType: "audio/mpeg")
        XCTAssertEqual(item.iconName, "music.note")
    }

    // MARK: - iconName: Archive

    func test_iconName_applicationZipMimeType_returnsArchivebox() {
        let item = makeItem(type: .file, mimeType: "application/zip")
        XCTAssertEqual(item.iconName, "archivebox")
    }

    // MARK: - iconName: Text

    func test_iconName_textPlainMimeType_returnsDocText() {
        let item = makeItem(type: .file, mimeType: "text/plain")
        XCTAssertEqual(item.iconName, "doc.text")
    }

    func test_iconName_textHtmlMimeType_returnsDocText() {
        let item = makeItem(type: .file, mimeType: "text/html")
        XCTAssertEqual(item.iconName, "doc.text")
    }

    // MARK: - iconName: Unknown / nil

    func test_iconName_unknownMimeType_returnsDoc() {
        let item = makeItem(type: .file, mimeType: "application/octet-stream")
        XCTAssertEqual(item.iconName, "doc")
    }

    func test_iconName_nilMimeType_returnsDoc() {
        let item = makeItem(type: .file, mimeType: nil)
        XCTAssertEqual(item.iconName, "doc")
    }
}
