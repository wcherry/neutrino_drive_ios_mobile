import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import os.log

// MARK: - ThumbnailGenerator

/// Makes the cover thumbnail that rides along with an encrypted upload.
///
/// A Drive file's preview tile cannot be produced server-side: the server holds ciphertext and
/// has no key, so anything it tried to decode would be random bytes. The client that still has
/// the plaintext is the only party that can make one, which is why every upload path generates
/// a thumbnail *before* encrypting and posts it in the same multipart request — see
/// `E2EEUploader.upload`. Without it a photo uploaded from this app shows as a blank tile with a
/// generic icon everywhere the platform renders covers.
///
/// The output matches the web's `generateThumbnail` (`web/packages/utils`) on every axis the
/// server and the other clients can observe: JPEG, longest edge at most 512px, never upscaled,
/// quality 0.8, raw base64 with no `data:` prefix. The server stores whatever arrives and hard-
/// codes `image/jpeg` as its MIME type, so producing anything else would serve a mislabelled
/// image.
///
/// Deliberately ImageIO rather than UIKit: this file compiles into the share extension too, and
/// `ImageIO` decodes HEIC — which is what an iPhone photo actually is — without the memory cost
/// of materialising the full-size image the way `UIImage(data:)` would.
///
/// Videos get a poster frame through `AVAssetImageGenerator`, encoded as the same 512px JPEG, so
/// a clip and a photo produce covers that are indistinguishable to every consumer — the server
/// stores one kind of thumbnail and the grids render one kind of tile.
enum ThumbnailGenerator {

    /// Longest edge of the generated thumbnail, in pixels. Matches the web's `maxSize`.
    static let maxPixelSize = 512

    /// JPEG quality. Matches the web's `canvas.toDataURL('image/jpeg', 0.8)`.
    static let compressionQuality = 0.8

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                       category: "ThumbnailGenerator")

    /// The `thumbnail_b64` value for an upload of `data`, or `nil` when the file is neither an
    /// image nor a video, or cannot be decoded.
    ///
    /// Returning `nil` is always an acceptable outcome: the server treats a missing thumbnail as
    /// a nicety it does without, and nothing here may cost the user their upload.
    ///
    /// A video has to reach `AVFoundation` as a file, so this spills `data` to a temporary file
    /// first. Callers that *already* hold the video on disk should use
    /// ``coverThumbnailBase64(forVideoAt:)`` instead and skip the copy — `PHKitAssetExporter`
    /// does, which is what keeps photo sync from writing a second copy of a half-gigabyte clip
    /// during a background drain.
    static func coverThumbnailBase64(for data: Data, mimeType: String) async -> String? {
        if mimeType.hasPrefix("image/") {
            guard let jpeg = jpegThumbnail(for: data) else {
                logger.info("no thumbnail for a \(mimeType, privacy: .public) upload")
                return nil
            }
            return jpeg.base64EncodedString()
        }
        if mimeType.hasPrefix("video/") {
            return await videoCoverThumbnailBase64(for: data, mimeType: mimeType)
        }
        return nil
    }

    /// The `thumbnail_b64` value for a video already on disk, or `nil` when no frame can be read.
    static func coverThumbnailBase64(forVideoAt url: URL) async -> String? {
        guard let jpeg = await jpegThumbnail(forVideoAt: url) else {
            logger.info("no poster frame for the video at \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        return jpeg.base64EncodedString()
    }

    /// Extracts a poster frame from the video at `url` as a JPEG bounded by ``maxPixelSize``.
    static func jpegThumbnail(forVideoAt url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        // A video shot in portrait is stored landscape plus a rotation in its track transform;
        // without this the cover is sideways — the same trap as an image's EXIF orientation.
        generator.appliesPreferredTrackTransform = true
        // Bounds the frame at the source, so the full-resolution image is never materialised.
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)

        do {
            let (image, _) = try await generator.image(at: posterFrameTime(for: asset))
            return encodeJPEG(image)
        } catch {
            logger.info("poster frame extraction failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// Downscales `data` to a JPEG no larger than ``maxPixelSize`` on its longest edge.
    static func jpegThumbnail(for data: Data) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            // `…FromImageAlways` rather than `…IfAbsent`: a camera photo carries an embedded EXIF
            // thumbnail that is both far smaller than 512px and, on an edited photo, a picture of
            // the *original*. Decoding from the image itself is the only way the tile shows what
            // the user actually uploaded.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation. Without it a photo taken in portrait — which is
            // stored landscape plus a rotation flag — produces a sideways tile.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return encodeJPEG(image)
    }

    // MARK: - Private

    /// Which frame to use as the cover.
    ///
    /// One second in, not zero: the first frame of a real recording is very often black or a
    /// blurred smear of the camera coming up, which makes for a tile that says nothing about the
    /// clip. Anything shorter than two seconds uses its midpoint instead, so a brief clip still
    /// gets a frame from inside itself rather than a clamped end.
    private static func posterFrameTime(for asset: AVAsset) async -> CMTime {
        let preferred = CMTime(seconds: 1, preferredTimescale: 600)
        // A duration that is indefinite or unreadable is not a reason to give up on the cover —
        // fall back to the preferred time and let the generator clamp it.
        guard let duration = try? await asset.load(.duration), duration.isNumeric,
              duration.seconds > 0 else {
            return preferred
        }
        return duration.seconds < 2 ? CMTimeMultiplyByFloat64(duration, multiplier: 0.5) : preferred
    }

    private static func videoCoverThumbnailBase64(for data: Data, mimeType: String) async -> String? {
        // AVFoundation reads containers from disk, and it leans on the path extension to pick a
        // demuxer — so the spill file is named for the MIME type rather than given a generic one.
        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "mov"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nd-thumb-\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        return await coverThumbnailBase64(forVideoAt: url)
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
