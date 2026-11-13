import XCTest
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers
import os.log
@testable import NeutrinoDrive

// MARK: - Fakes

/// A picker result backed by a file the test wrote, standing in for `PHPickerResult`.
private struct FakePickedItem: PickedItem {
    var assetIdentifier: String?
    var suggestedName: String?
    var registeredTypeIdentifiers: [String]
    /// The bytes `loadFile` hands back, as if the provider had copied them out.
    var fileBytes: Data
    var fileExtension: String

    func loadFile(forTypeIdentifier typeIdentifier: String) async throws -> URL {
        // Its own directory, as `ItemProviderAttachment.loadFile()` makes one, since the loader
        // removes the whole directory when it's done.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("version=1&uuid=X.\(fileExtension)")
        try fileBytes.write(to: url)
        return url
    }
}

private struct FakeExporter: PhotoAssetExporting {
    var result: Result<PhotoExport, Error>
    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport {
        try result.get()
    }
}

// MARK: - Fixtures

/// A small JPEG carrying `DateTimeOriginal`, and `OffsetTimeOriginal` when given.
private func jpegWithExif(dateTimeOriginal: String?, offset: String? = nil) -> Data {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
        UIColor.red.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    var exif: [CFString: Any] = [:]
    if let dateTimeOriginal { exif[kCGImagePropertyExifDateTimeOriginal] = dateTimeOriginal }
    if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image.cgImage!,
                               [kCGImagePropertyExifDictionary: exif] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
}

private func utc(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

// MARK: - Tests

final class PickedMediaLoaderTests: XCTestCase {

    // MARK: Type choice

    func testPrefersTheOriginalImageOverTheLivePhotoBundleAndRenderings() {
        let chosen = PickedMediaLoader.preferredTypeIdentifier(
            ["com.apple.live-photo-bundle", UTType.heic.identifier, UTType.jpeg.identifier]
        )
        XCTAssertEqual(chosen, UTType.heic.identifier)
    }

    func testAcceptsAMovie() {
        XCTAssertEqual(PickedMediaLoader.preferredTypeIdentifier([UTType.quickTimeMovie.identifier]),
                       UTType.quickTimeMovie.identifier)
    }

    func testRejectsAnythingThatIsNotAnImageOrMovie() {
        XCTAssertNil(PickedMediaLoader.preferredTypeIdentifier([UTType.plainText.identifier]))
        XCTAssertNil(PickedMediaLoader.preferredTypeIdentifier([]))
    }

    // MARK: Naming

    func testAppendsTheTypesExtensionToASuggestedName() {
        XCTAssertEqual(PickedMediaLoader.fileName(suggested: "IMG_1234", type: .heic, fallbackDate: Date()),
                       "IMG_1234.heic")
    }

    func testKeepsASuggestedNameThatAlreadyHasTheExtension() {
        XCTAssertEqual(PickedMediaLoader.fileName(suggested: "IMG_1234.HEIC", type: .heic, fallbackDate: Date()),
                       "IMG_1234.HEIC")
        XCTAssertEqual(PickedMediaLoader.fileName(suggested: "IMG_1234.jpg", type: .jpeg, fallbackDate: Date()),
                       "IMG_1234.jpg")
    }

    func testDoesNotMistakeADotInTheNameForAnExtension() {
        XCTAssertEqual(PickedMediaLoader.fileName(suggested: "Trip v1.2", type: .jpeg, fallbackDate: Date()),
                       "Trip v1.2.jpeg")
    }

    func testFallsBackToTheExportersDatedNameWithNoSuggestion() {
        let date = utc("2019-07-04T10:30:00Z")
        XCTAssertEqual(PickedMediaLoader.fileName(suggested: nil, type: .jpeg, fallbackDate: date),
                       PHKitAssetExporter.fallbackFileName(creationDate: date, ext: "jpeg"))
        XCTAssertEqual(PickedMediaLoader.fileName(suggested: "  ", type: .jpeg, fallbackDate: date),
                       PHKitAssetExporter.fallbackFileName(creationDate: date, ext: "jpeg"))
    }

    // MARK: EXIF dates

    func testReadsDateTimeOriginalWithItsOffset() throws {
        let url = try writeTemp(jpegWithExif(dateTimeOriginal: "2019:07:04 10:30:00", offset: "+02:00"), ext: "jpg")
        XCTAssertEqual(PickedMediaLoader.exifCaptureDate(at: url), utc("2019-07-04T08:30:00Z"))
    }

    func testReadsDateTimeOriginalWithoutAnOffsetAsLocalTime() throws {
        let url = try writeTemp(jpegWithExif(dateTimeOriginal: "2019:07:04 10:30:00"), ext: "jpg")
        let newYork = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(PickedMediaLoader.exifCaptureDate(at: url, timeZone: newYork),
                       utc("2019-07-04T14:30:00Z"))
    }

    func testNoDateWhenTheImageHasNone() throws {
        let url = try writeTemp(jpegWithExif(dateTimeOriginal: nil), ext: "jpg")
        XCTAssertNil(PickedMediaLoader.exifCaptureDate(at: url))
    }

    func testIgnoresAMalformedOffset() {
        let utcZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(PickedMediaLoader.parseExifDate("2019:07:04 10:30:00", offset: "garbage",
                                                      defaultTimeZone: utcZone),
                       utc("2019-07-04T10:30:00Z"))
        XCTAssertEqual(PickedMediaLoader.parseExifDate("2019:07:04 10:30:00", offset: "-05:30",
                                                      defaultTimeZone: utcZone),
                       utc("2019-07-04T16:00:00Z"))
    }

    // MARK: Library route

    func testUsesTheLibraryExportWhenTheAssetCanBeRead() async throws {
        let created = utc("2018-05-01T12:00:00Z")
        let edited = utc("2020-01-01T09:00:00Z")
        let export = PhotoExport(data: Data([1, 2, 3]), fileName: "IMG_0001.HEIC", mimeType: "image/heic")
        var loader = PickedMediaLoader()
        loader.exporter = FakeExporter(result: .success(export))
        loader.canReadLibrary = { true }
        loader.assetDates = { _ in (created, edited) }

        let item = FakePickedItem(assetIdentifier: "ASSET-1", suggestedName: "IMG_0001",
                                  registeredTypeIdentifiers: [UTType.heic.identifier],
                                  fileBytes: Data([9]), fileExtension: "heic")
        let media = try await loader.load(item)

        XCTAssertEqual(media.data, Data([1, 2, 3]))
        XCTAssertEqual(media.fileName, "IMG_0001.HEIC")
        XCTAssertEqual(media.mimeType, "image/heic")
        XCTAssertEqual(media.importMetadata,
                       DriveImportMetadata(createdAt: created, updatedAt: edited,
                                           importSource: "photo-upload:ASSET-1"))
    }

    func testFallsBackToThePickersFileWhenTheExportFails() async throws {
        // An asset outside a limited selection isn't found; the provider still has it.
        let original = jpegWithExif(dateTimeOriginal: "2019:07:04 10:30:00", offset: "+00:00")
        var loader = PickedMediaLoader()
        loader.exporter = FakeExporter(result: .failure(PhotoExportError.assetNotFound))
        loader.canReadLibrary = { true }

        let item = FakePickedItem(assetIdentifier: "ASSET-2", suggestedName: "IMG_0002",
                                  registeredTypeIdentifiers: [UTType.jpeg.identifier],
                                  fileBytes: original, fileExtension: "jpg")
        let media = try await loader.load(item)

        XCTAssertEqual(media.data, original, "the picked file must be uploaded byte for byte")
        XCTAssertEqual(media.fileName, "IMG_0002.jpeg")
        XCTAssertEqual(media.mimeType, "image/jpeg")
        XCTAssertEqual(media.importMetadata?.createdAt, utc("2019-07-04T10:30:00Z"))
        XCTAssertEqual(media.importMetadata?.importSource, "photo-upload:ASSET-2")
    }

    func testSkipsTheLibraryWithoutAccess() async throws {
        let original = jpegWithExif(dateTimeOriginal: nil)
        var loader = PickedMediaLoader()
        loader.exporter = FakeExporter(result: .success(
            PhotoExport(data: Data([0]), fileName: "wrong", mimeType: "image/jpeg")
        ))
        loader.canReadLibrary = { false }
        loader.now = { utc("2024-03-02T01:02:03Z") }

        let item = FakePickedItem(assetIdentifier: "ASSET-3", suggestedName: nil,
                                  registeredTypeIdentifiers: [UTType.jpeg.identifier],
                                  fileBytes: original, fileExtension: "jpg")
        let media = try await loader.load(item)

        XCTAssertEqual(media.data, original)
        XCTAssertNil(media.importMetadata, "no EXIF date means the upload's own date")
        XCTAssertEqual(media.fileName,
                       PHKitAssetExporter.fallbackFileName(creationDate: utc("2024-03-02T01:02:03Z"),
                                                           ext: "jpeg"))
    }

    func testThrowsForAnItemWithNoPhotoOrVideo() async {
        var loader = PickedMediaLoader()
        loader.canReadLibrary = { false }
        let item = FakePickedItem(assetIdentifier: nil, suggestedName: "notes",
                                  registeredTypeIdentifiers: [UTType.plainText.identifier],
                                  fileBytes: Data(), fileExtension: "txt")
        do {
            _ = try await loader.load(item)
            XCTFail("expected unsupportedItem")
        } catch PickedMediaError.unsupportedItem {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testImportSourceWithoutAnAssetIdentifier() {
        XCTAssertEqual(PickedMediaLoader.importSource(assetIdentifier: nil), "photo-upload")
        XCTAssertEqual(PickedMediaLoader.importSource(assetIdentifier: ""), "photo-upload")
    }

    // MARK: Import-metadata fallback

    private let logger = Logger(subsystem: "tests", category: "PickedMediaLoaderTests")
    private let metadata = DriveImportMetadata(createdAt: utc("2019-07-04T10:30:00Z"),
                                               updatedAt: utc("2019-07-04T10:30:00Z"),
                                               importSource: "photo-upload:A")

    private func result(importSource: String?) -> UploadResult {
        UploadResult(id: "file-1", name: "IMG.jpg", folderId: nil, sizeBytes: 1,
                     mimeType: "image/jpeg", updatedAt: Date(), importSource: importSource)
    }

    func testPatchesWhenTheServerDidNotKeepTheDates() async {
        var patched: [String] = []
        await PickedMediaUpload.stampIfNeeded(result: result(importSource: nil), metadata: metadata,
                                              stamp: { id, _ in patched.append(id) }, logger: logger)
        XCTAssertEqual(patched, ["file-1"])
    }

    func testDoesNotPatchWhenTheServerKeptTheDates() async {
        var patched = 0
        await PickedMediaUpload.stampIfNeeded(result: result(importSource: "photo-upload:A"),
                                              metadata: metadata,
                                              stamp: { _, _ in patched += 1 }, logger: logger)
        XCTAssertEqual(patched, 0)
    }

    func testDoesNotPatchWithoutADate() async {
        var patched = 0
        await PickedMediaUpload.stampIfNeeded(result: result(importSource: nil), metadata: nil,
                                              stamp: { _, _ in patched += 1 }, logger: logger)
        XCTAssertEqual(patched, 0)
    }

    func testAFailedPatchIsSwallowed() async {
        struct Boom: Error {}
        await PickedMediaUpload.stampIfNeeded(result: result(importSource: nil), metadata: metadata,
                                              stamp: { _, _ in throw Boom() }, logger: logger)
        // Reaching here is the assertion: the upload already succeeded and must not fail now.
    }

    // MARK: Camera

    func testCameraCaptureKeepsItsMetadataAndOrientation() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        }
        let rotated = UIImage(cgImage: image.cgImage!, scale: 1, orientation: .right)
        let metadata: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:11:13 09:15:00",
                kCGImagePropertyExifLensModel as String: "Test Lens",
            ],
        ]
        let captured = utc("2026-11-13T09:15:00Z")

        for preferHEIC in [true, false] {
            let media = try CameraCaptureEncoder.encode(image: rotated, metadata: metadata,
                                                        capturedAt: captured, preferHEIC: preferHEIC)
            XCTAssertNil(media.importMetadata)
            let ext = (media.fileName as NSString).pathExtension
            XCTAssertEqual(UTType(filenameExtension: ext)?.preferredMIMEType, media.mimeType)
            XCTAssertTrue(media.fileName.hasPrefix("IMG_"))

            let source = try XCTUnwrap(CGImageSourceCreateWithData(media.data as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
            XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:11:13 09:15:00")
            XCTAssertEqual(exif[kCGImagePropertyExifLensModel] as? String, "Test Lens")
            XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
                           CGImagePropertyOrientation.right.rawValue)
        }
    }

    // MARK: Helpers

    private func writeTemp(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
