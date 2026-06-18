import XCTest
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
