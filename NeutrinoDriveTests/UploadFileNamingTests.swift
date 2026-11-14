import XCTest
@testable import NeutrinoDrive

// MARK: - Rule

final class UploadFileNamingTests: XCTestCase {

    private func name(_ suggested: String?, _ ext: String, loaded: String? = nil) -> String {
        UploadFileNaming.name(suggested: suggested, fileExtension: ext, loadedFileName: loaded,
                              fallbackStem: { "Shared 20261113_141500" })
    }

    func testAddsTheFilesExtensionToABareSuggestion() {
        XCTAssertEqual(name("IMG_1234", "heic"), "IMG_1234.heic")
        XCTAssertEqual(name("Quarterly report", "pdf"), "Quarterly report.pdf")
    }

    func testKeepsASuggestionThatAlreadyHasTheExtension() {
        XCTAssertEqual(name("IMG_1234.HEIC", "heic"), "IMG_1234.HEIC", "no IMG_1234.HEIC.heic")
        XCTAssertEqual(name("IMG_1234.jpg", "jpeg"), "IMG_1234.jpg", "jpg and jpeg are the same type")
        XCTAssertEqual(name("clip.MOV", "mov"), "clip.MOV")
    }

    func testAddsTheExtensionWhenTheSuggestionsIsOfAnotherType() {
        // The bytes are what they are: a name claiming PNG for HEIC data gets the real one too.
        XCTAssertEqual(name("IMG_1234.png", "heic"), "IMG_1234.png.heic")
    }

    func testADotInTheNameIsNotAnExtension() {
        XCTAssertEqual(name("Trip v1.2", "jpg"), "Trip v1.2.jpg")
        XCTAssertEqual(name("Mr. Smith", "pdf"), "Mr. Smith.pdf")
    }

    func testWithNoExtensionToAddTheSuggestionIsUnchanged() {
        XCTAssertEqual(name("README", ""), "README")
    }

    func testWithNoSuggestionUsesTheLoadedFilesOwnName() {
        XCTAssertEqual(name(nil, "pdf", loaded: "Invoice 42.pdf"), "Invoice 42.pdf")
        XCTAssertEqual(name("  ", "heic", loaded: "photo.heic"), "photo.heic")
    }

    func testWithNoSuggestionIgnoresAnOpaqueTempName() {
        XCTAssertEqual(name(nil, "jpeg", loaded: "version=1&uuid=ABC&mode=compatible.jpeg"),
                       "Shared 20261113_141500.jpeg")
        XCTAssertEqual(name(nil, "heic", loaded: "\(UUID().uuidString).heic"),
                       "Shared 20261113_141500.heic")
        XCTAssertEqual(name(nil, "heic"), "Shared 20261113_141500.heic")
    }

    func testTheFallbackStemIsDated() {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 11, 13)
        (components.hour, components.minute, components.second) = (14, 15, 0)
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(UploadFileNaming.sharedFallbackStem(at: date), "Shared 20261113_141500")
    }
}

// MARK: - Share extension

/// A shared file whose sender suggested `providerSuggestedName`, loaded as `fileName`.
private final class NamedShare: ShareAttachment {
    let providerSuggestedName: String?
    let fileName: String
    var suggestedName: String { providerSuggestedName ?? "Shared item" }

    init(suggested: String?, file: String) {
        providerSuggestedName = suggested
        fileName = file
    }

    func loadFile() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("named-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try Data("bytes".utf8).write(to: url)
        return url
    }
}

final class ShareUploadNamingTests: XCTestCase {

    private func run(_ items: [ShareAttachment]) async -> (names: [String], mimes: [String], results: [ShareItemResult]) {
        let sut = ShareUploadCoordinator()
        sut.hasStoredKeysProvider = { true }
        sut.hasAccessTokenProvider = { true }
        sut.keepsLivePhotoMotion = { true }
        var names: [String] = []
        var mimes: [String] = []
        sut.uploadHandler = { data, name, mime, _ in
            names.append(name)
            mimes.append(mime)
            return UploadResult(id: "id-\(name)", name: name, folderId: nil,
                                sizeBytes: Int64(data.count), mimeType: mime, updatedAt: Date())
        }
        let results = await sut.run(attachments: items)
        return (names, mimes, results)
    }

    func testASharedPhotoIsUploadedWithItsExtension() async {
        let (names, mimes, results) = await run([NamedShare(suggested: "IMG_1234", file: "IMG_1234.HEIC")])
        XCTAssertEqual(names, ["IMG_1234.HEIC"])
        XCTAssertEqual(mimes, ["image/heic"])
        XCTAssertEqual(results.first?.name, "IMG_1234", "the result list keeps the name it showed before")
    }

    func testTheExtensionComesFromTheBytesNotTheTempName() async {
        let (names, _, _) = await run([
            NamedShare(suggested: "IMG_1234", file: "version=1&uuid=X.heic"),
            NamedShare(suggested: "Notes.pdf", file: "tmp123.pdf"),
            NamedShare(suggested: "Holiday", file: "clip.mov"),
        ])
        XCTAssertEqual(names, ["IMG_1234.heic", "Notes.pdf", "Holiday.mov"])
    }

    func testANamelessShareGetsADatedNameWithTheExtension() async {
        let (names, _, _) = await run([NamedShare(suggested: nil, file: "version=1&uuid=X.jpeg")])
        let name = try? XCTUnwrap(names.first)
        XCTAssertTrue(name?.hasPrefix("Shared ") == true, "got \(String(describing: name))")
        XCTAssertTrue(name?.hasSuffix(".jpeg") == true, "got \(String(describing: name))")
    }

    func testALivePhotosStillIsNamedTheSameWithMotionOnOrOff() {
        // With motion off the share goes through the plain path, which now names it by the same
        // rule as the Live Photo path's still.
        let plain = UploadFileNaming.name(suggested: "IMG_1234", fileExtension: "heic",
                                          fallbackStem: { "x" })
        let live = ShareUploadCoordinator.stillFileName(suggested: "IMG_1234",
                                                        file: URL(fileURLWithPath: "/tmp/b/photo.heic"))
        XCTAssertEqual(plain, live)
        XCTAssertEqual(live, "IMG_1234.heic")
    }
}
