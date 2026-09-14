import XCTest
import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
@testable import NeutrinoDrive

// MARK: - Fixtures

/// Encodes a solid-colour PNG of the requested pixel dimensions.
///
/// Shared with `E2EEUploaderTests`, which needs real decodable image bytes to prove the upload
/// carries a cover thumbnail. Generated rather than checked in so the dimensions — the thing the
/// downscaling assertions turn on — are visible at the call site.
func makeTestPNG(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!

    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// Encodes a real H.264 video of `frames` solid red frames at 30fps.
///
/// Genuinely encoded rather than a stub file, because what the video path has to be trusted about
/// is that `AVAssetImageGenerator` gets a decodable frame out of a real container — a fixture that
/// faked that would assert nothing. Red so a test can tell a decoded frame from the black one a
/// failed extraction would leave behind.
func makeTestVideo(width: Int = 640, height: Int = 480, frames: Int = 90) async throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("nd-test-video-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let pool = try XCTUnwrap(adaptor.pixelBufferPool)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { await Task.yield() }

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.setFillColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }

    input.markAsFinished()
    await writer.finishWriting()
    return url
}

/// The pixel dimensions of encoded image `data`, read from its header.
private func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
}

/// The average colour of encoded image `data`, by decoding it into a 1×1 bitmap.
private func averageColour(of data: Data) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }

    // Allocated rather than a local array's buffer: the context outlives the call that hands it
    // the pointer, so an array's storage would be escaping.
    let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
    pixel.initialize(repeating: 0, count: 4)
    defer { pixel.deallocate() }

    guard let context = CGContext(data: pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (pixel[0], pixel[1], pixel[2])
}

// MARK: - ThumbnailGeneratorTests

/// The server cannot make a preview of an encrypted file, so these are the only guarantees
/// standing behind a Drive photo having a cover image at all.
final class ThumbnailGeneratorTests: XCTestCase {

    // MARK: - Sizing

    func test_thumbnail_boundsTheLongestEdgeToMaxPixelSize() throws {
        let thumbnail = try XCTUnwrap(ThumbnailGenerator.jpegThumbnail(for: makeTestPNG(width: 2000, height: 1000)))
        let size = try XCTUnwrap(pixelSize(of: thumbnail))
        XCTAssertEqual(size.width, ThumbnailGenerator.maxPixelSize)
        XCTAssertEqual(size.height, ThumbnailGenerator.maxPixelSize / 2)
    }

    func test_thumbnail_boundsTheLongestEdge_forAPortraitImageToo() throws {
        let thumbnail = try XCTUnwrap(ThumbnailGenerator.jpegThumbnail(for: makeTestPNG(width: 1000, height: 2000)))
        let size = try XCTUnwrap(pixelSize(of: thumbnail))
        XCTAssertEqual(size.height, ThumbnailGenerator.maxPixelSize)
        XCTAssertEqual(size.width, ThumbnailGenerator.maxPixelSize / 2)
    }

    func test_thumbnail_neverUpscalesAnImageSmallerThanTheBound() throws {
        // Matches the web's `Math.min(..., 1)` scale clamp — blowing a 64px icon up to 512
        // costs bytes and adds nothing.
        let thumbnail = try XCTUnwrap(ThumbnailGenerator.jpegThumbnail(for: makeTestPNG(width: 64, height: 48)))
        let size = try XCTUnwrap(pixelSize(of: thumbnail))
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 48)
    }

    // MARK: - Format
    //
    // The server hard-codes `image/jpeg` as the stored thumbnail's MIME type, so anything else
    // produced here is served mislabelled.

    func test_thumbnail_isAlwaysJPEG_evenFromAPNGSource() throws {
        let thumbnail = try XCTUnwrap(ThumbnailGenerator.jpegThumbnail(for: makeTestPNG(width: 800, height: 800)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func test_thumbnail_isSmallEnoughToRideAlongWithTheUpload() throws {
        // The whole point of a 512px cover is that it costs the upload almost nothing.
        let thumbnail = try XCTUnwrap(ThumbnailGenerator.jpegThumbnail(for: makeTestPNG(width: 4032, height: 3024)))
        XCTAssertLessThan(thumbnail.count, 200_000)
    }

    // MARK: - The `thumbnail_b64` value

    func test_coverThumbnail_isRawBase64_withNoDataURLPrefix() async throws {
        // The web posts `dataUrl.split(',')[1]` and the server base64-decodes the field as-is; a
        // `data:image/jpeg;base64,` prefix would fail that decode and the thumbnail would be
        // discarded server-side.
        let cover = await ThumbnailGenerator.coverThumbnailBase64(
            for: makeTestPNG(width: 300, height: 300), mimeType: "image/png")
        let encoded = try XCTUnwrap(cover)
        XCTAssertFalse(encoded.hasPrefix("data:"))
        XCTAssertNotNil(Data(base64Encoded: encoded))
    }

    func test_coverThumbnail_decodesBackToTheJPEGThatWasGenerated() async throws {
        let png = makeTestPNG(width: 640, height: 480)
        let cover = await ThumbnailGenerator.coverThumbnailBase64(for: png, mimeType: "image/png")
        let encoded = try XCTUnwrap(cover)
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertEqual(decoded, ThumbnailGenerator.jpegThumbnail(for: png))
    }

    // MARK: - Video poster frames

    func test_videoThumbnail_isAJPEGBoundedToMaxPixelSize() async throws {
        let url = try await makeTestVideo(width: 1024, height: 768, frames: 90)
        defer { try? FileManager.default.removeItem(at: url) }

        let poster = await ThumbnailGenerator.jpegThumbnail(forVideoAt: url)
        let thumbnail = try XCTUnwrap(poster)
        let size = try XCTUnwrap(pixelSize(of: thumbnail))
        XCTAssertEqual(max(size.width, size.height), ThumbnailGenerator.maxPixelSize)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func test_videoThumbnail_containsAnActuallyDecodedFrame() async throws {
        // The failure this guards against is the quiet one: a generator that hands back a black
        // or empty frame still produces a valid JPEG, and every structural assertion above would
        // pass while the tile showed nothing. The fixture is solid red, so the cover must be too.
        let url = try await makeTestVideo(frames: 90)
        defer { try? FileManager.default.removeItem(at: url) }

        let poster = await ThumbnailGenerator.jpegThumbnail(forVideoAt: url)
        let thumbnail = try XCTUnwrap(poster)
        let colour = try XCTUnwrap(averageColour(of: thumbnail))
        XCTAssertGreaterThan(colour.r, 150, "the poster frame is not the red the fixture encoded")
        XCTAssertGreaterThan(Int(colour.r), Int(colour.g) + 80)
        XCTAssertGreaterThan(Int(colour.r), Int(colour.b) + 80)
    }

    func test_videoThumbnail_worksForAClipShorterThanThePreferredPosterTime() async throws {
        // 10 frames at 30fps is a third of a second — shorter than the 1s the generator would
        // otherwise seek to. A clip this short is exactly what a mis-clamped seek loses.
        let url = try await makeTestVideo(frames: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let poster = await ThumbnailGenerator.jpegThumbnail(forVideoAt: url)
        XCTAssertNotNil(poster)
    }

    func test_coverThumbnail_makesAVideoCoverFromInMemoryBytes() async throws {
        // The path a share-extension or upload-sheet video takes: no file, just the bytes.
        let url = try await makeTestVideo(frames: 90)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)

        let cover = await ThumbnailGenerator.coverThumbnailBase64(for: data, mimeType: "video/quicktime")
        let encoded = try XCTUnwrap(cover)
        XCTAssertNotNil(Data(base64Encoded: encoded))
    }

    func test_coverThumbnail_leavesNoSpillFileBehind_afterAVideoCover() async throws {
        let url = try await makeTestVideo(frames: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)

        let tmp = FileManager.default.temporaryDirectory
        let before = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?
            .filter { $0.hasPrefix("nd-thumb-") }.count ?? 0

        _ = await ThumbnailGenerator.coverThumbnailBase64(for: data, mimeType: "video/quicktime")

        let after = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?
            .filter { $0.hasPrefix("nd-thumb-") }.count ?? 0
        XCTAssertEqual(after, before, "a spilled copy of every uploaded video would be left in tmp")
    }

    // MARK: - Refusals

    func test_coverThumbnail_isNilForAMimeTypeThatIsNeitherImageNorVideo() async {
        let png = makeTestPNG(width: 100, height: 100)
        let cover = await ThumbnailGenerator.coverThumbnailBase64(for: png, mimeType: "application/pdf")
        XCTAssertNil(cover)
        let textCover = await ThumbnailGenerator.coverThumbnailBase64(for: Data("hello".utf8),
                                                                      mimeType: "text/plain")
        XCTAssertNil(textCover)
    }

    func test_coverThumbnail_isNilWhenTheBytesAreNotDecodableAsAnImage() async {
        let cover = await ThumbnailGenerator.coverThumbnailBase64(for: Data("not an image".utf8),
                                                                  mimeType: "image/jpeg")
        XCTAssertNil(cover)
    }

    func test_coverThumbnail_isNilWhenTheBytesAreNotDecodableAsAVideo() async {
        let cover = await ThumbnailGenerator.coverThumbnailBase64(for: Data("not a video".utf8),
                                                                  mimeType: "video/quicktime")
        XCTAssertNil(cover)
    }

    func test_thumbnail_isNilForEmptyData() {
        XCTAssertNil(ThumbnailGenerator.jpegThumbnail(for: Data()))
    }
}
