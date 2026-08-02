import XCTest
@testable import NeutrinoDrive

/// Unit tests for `FileKind.classify` — the single mapping from (MIME, filename, folder-ness)
/// to the icon an item gets.
final class FileKindTests: XCTestCase {

    private func classify(_ mimeType: String?, _ filename: String = "Untitled") -> FileKind {
        FileKind.classify(mimeType: mimeType, filename: filename, isFolder: false)
    }

    // MARK: - MIME normalisation

    /// The Mac client already has to tolerate this shape, so the server evidently emits it.
    func test_classify_stripsMimeParameters() {
        XCTAssertEqual(classify("text/plain; charset=utf-8"), .text)
        XCTAssertEqual(classify("\(NeutrinoMIME.doc); charset=utf-8"), .neutrinoDoc)
    }

    func test_classify_isCaseInsensitive() {
        XCTAssertEqual(classify("IMAGE/JPEG"), .image)
        XCTAssertEqual(classify("Application/PDF"), .pdf)
    }

    func test_classify_trimsWhitespace() {
        XCTAssertEqual(classify("  application/pdf  "), .pdf)
    }

    // MARK: - Neutrino native formats

    func test_classify_unknownNeutrinoType_stillClassifiesAsNative() {
        // A seventh editor shipping server-side before this app is rebuilt should get Neutrino
        // artwork, not a blank page.
        let kind = classify("application/x-neutrino-whiteboard")
        XCTAssertTrue(kind.isNeutrinoNative)
        XCTAssertNotNil(kind.assetName)
    }

    func test_assetName_isPresentForExactlyTheNeutrinoKinds() {
        for kind in FileKind.allCases {
            XCTAssertEqual(kind.assetName != nil, kind.isNeutrinoNative,
                           "\(kind) disagrees about having custom artwork")
        }
    }

    func test_symbolName_isNonEmptyForEveryKind() {
        for kind in FileKind.allCases {
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind) has no fallback symbol")
        }
    }

    // MARK: - Office documents

    func test_classify_officeMimeTypes() {
        XCTAssertEqual(classify("application/vnd.openxmlformats-officedocument.wordprocessingml.document"), .document)
        XCTAssertEqual(classify("application/msword"), .document)
        XCTAssertEqual(classify("application/vnd.oasis.opendocument.text"), .document)
        XCTAssertEqual(classify("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"), .spreadsheet)
        XCTAssertEqual(classify("application/vnd.ms-excel"), .spreadsheet)
        XCTAssertEqual(classify("text/csv"), .spreadsheet)
        XCTAssertEqual(classify("application/vnd.openxmlformats-officedocument.presentationml.presentation"), .presentation)
        XCTAssertEqual(classify("application/vnd.ms-powerpoint"), .presentation)
    }

    // MARK: - Code and data

    func test_classify_jsonMimeType() {
        XCTAssertEqual(classify("application/json"), .json)
    }

    func test_classify_codeMimeTypes() {
        XCTAssertEqual(classify("application/javascript"), .code)
        XCTAssertEqual(classify("text/css"), .code)
        XCTAssertEqual(classify("application/xml"), .code)
    }

    func test_classify_archiveMimeTypes() {
        XCTAssertEqual(classify("application/zip"), .archive)
        XCTAssertEqual(classify("application/x-tar"), .archive)
        XCTAssertEqual(classify("application/x-7z-compressed"), .archive)
        XCTAssertEqual(classify("application/gzip"), .archive)
    }

    // MARK: - Extension fallback

    func test_classify_genericMimeTypes_deferToTheExtension() {
        for generic in ["application/octet-stream", "binary/octet-stream", "content/unknown", ""] {
            XCTAssertEqual(FileKind.classify(mimeType: generic, filename: "holiday.HEIC", isFolder: false),
                           .image, "\(generic) did not defer to the filename")
        }
    }

    func test_classify_nilMimeType_defersToTheExtension() {
        XCTAssertEqual(classify(nil, "notes.md"), .text)
        XCTAssertEqual(classify(nil, "main.swift"), .code)
        XCTAssertEqual(classify(nil, "budget.xlsx"), .spreadsheet)
        XCTAssertEqual(classify(nil, "deck.key"), .presentation)
        XCTAssertEqual(classify(nil, "backup.tar.gz"), .archive)
    }

    /// A real MIME type outranks the extension — the server knows better than a filename a
    /// user typed.
    func test_classify_mimeTypeWins_overAContradictoryExtension() {
        XCTAssertEqual(classify("application/pdf", "report.png"), .pdf)
    }

    func test_classify_unknownExtension_isUnknown() {
        XCTAssertEqual(classify(nil, "firmware.qqq"), .unknown)
        XCTAssertEqual(classify(nil, "no-extension-at-all"), .unknown)
    }

    // MARK: - Folders

    func test_classify_folder_beatsEverythingElse() {
        XCTAssertEqual(FileKind.classify(mimeType: "image/png", filename: "Photos.png", isFolder: true),
                       .folder)
    }
}
