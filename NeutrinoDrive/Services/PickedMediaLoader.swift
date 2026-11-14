import Foundation
import AVFoundation
import ImageIO
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import os.log

// MARK: - PickedMedia

/// One photo or video from the upload sheet, ready to encrypt and send.
///
/// The bytes are the file the user picked, unmodified, with no re-encoding. Before #43 the
/// library picker decoded every pick to a `UIImage` and re-encoded it as a JPEG, which cost the
/// original format, every byte of EXIF, the filename and the capture date.
struct PickedMedia {
    let data: Data
    let fileName: String
    let mimeType: String
    /// When the picture was taken, sent with the upload. `nil` when nothing says, and then the
    /// file is dated by the upload, as any other new file is.
    let importMetadata: DriveImportMetadata?
    /// A cover the loader could make more cheaply than the uploader: a video's, taken while the
    /// clip is still on disk. `nil` lets the uploader derive one from `data`.
    var thumbnailBase64: String? = nil
}

enum PickedMediaError: LocalizedError {
    /// The picked item offered no image or movie representation.
    case unsupportedItem
    /// The camera returned a picture that could not be written out.
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedItem: return "This item isn't a photo or video that can be uploaded."
        case .encodingFailed:  return "The photo could not be saved for upload."
        }
    }
}

// MARK: - PickedItem

/// What the loader needs from one picker result.
///
/// A protocol because `PHPickerResult` and its `NSItemProvider` can't be built in a test target.
protocol PickedItem {
    /// The `PHAsset.localIdentifier`, filled in because the picker is created with
    /// `PHPickerConfiguration(photoLibrary: .shared())`. Present even without library access;
    /// whether the asset can be *read* is a separate question.
    var assetIdentifier: String? { get }
    var suggestedName: String? { get }
    /// In the provider's own order, highest fidelity first.
    var registeredTypeIdentifiers: [String] { get }
    /// Copies the representation for `typeIdentifier` to a file the caller owns.
    func loadFile(forTypeIdentifier typeIdentifier: String) async throws -> URL
}

/// Production ``PickedItem`` over a `PHPickerResult`.
struct PickerResultItem: PickedItem {
    let result: PHPickerResult

    var assetIdentifier: String? { result.assetIdentifier }
    var suggestedName: String? { result.itemProvider.suggestedName }
    var registeredTypeIdentifiers: [String] { result.itemProvider.registeredTypeIdentifiers }

    func loadFile(forTypeIdentifier typeIdentifier: String) async throws -> URL {
        // The share extension's attachment already does exactly this, including copying the
        // file out before the provider deletes it.
        try await ItemProviderAttachment(provider: result.itemProvider,
                                         typeIdentifier: typeIdentifier).loadFile()
    }
}

// MARK: - PickedMediaLoader

/// Turns a picker result into the original file and its capture date.
///
/// Two routes, best first:
///
/// 1. **From the library**, when the app can read the asset. The same `PHKitAssetExporter` photo
///    sync uses: the original bytes and filename, and the asset's own creation and modification
///    dates. A Live Photo brings its motion too, as a second file named after the still (#42),
///    when **Keep Live Photo Motion** is on.
/// 2. **From the item provider**, when it can't (no or limited access). The original file
///    representation, named after the provider's suggested name, dated from its EXIF
///    `DateTimeOriginal` (a photo) or its QuickTime creation date (a video).
struct PickedMediaLoader {

    var exporter: PhotoAssetExporting = PHKitAssetExporter()
    /// Whether PhotoKit will hand over assets at all. A limited grant counts: an asset outside
    /// the selection simply isn't found, and the loader falls back.
    var canReadLibrary: () -> Bool = {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }
    /// An asset's creation and modification dates. Defaults to PhotoKit; tests inject.
    var assetDates: (String) -> (created: Date, modified: Date?)? = { identifier in
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let created = asset.creationDate else { return nil }
        return (created, asset.modificationDate)
    }
    var now: () -> Date = Date.init
    /// Photo sync's **Keep Live Photo Motion** setting, which manual uploads follow too.
    var keepsLivePhotoMotion: () -> Bool = { PhotoSyncKeys.keepsLivePhotoMotion(PhotoSyncDefaults.shared) }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "PickedMediaLoader")

    /// The files one pick uploads as: the photo or video, then a Live Photo's motion if any.
    func load(_ item: PickedItem) async throws -> [PickedMedia] {
        if let identifier = item.assetIdentifier, canReadLibrary() {
            do {
                let still = try await loadFromLibrary(identifier: identifier)
                return [still] + (await loadMotion(identifier: identifier, still: still).map { [$0] } ?? [])
            } catch {
                // Typically an asset outside a limited selection. The provider still has it.
                logger.info("library export of \(identifier, privacy: .public) failed, using the picker's file: \(error.localizedDescription, privacy: .public)")
            }
        }
        return [try await loadFromProvider(item)]
    }

    /// A Live Photo's paired video, or `nil` for anything else. Never throws: a clip that can't
    /// be read costs the motion, not the photo.
    private func loadMotion(identifier: String, still: PickedMedia) async -> PickedMedia? {
        guard keepsLivePhotoMotion() else { return nil }
        do {
            let clip = try await exporter.exportPairedVideo(for: identifier, networkAccessAllowed: true)
            let metadata = still.importMetadata.map {
                DriveImportMetadata(createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                                    importSource: Self.importSource(assetIdentifier: identifier) + PhotoSyncRules.motionSuffix)
            }
            return PickedMedia(data: clip.data, fileName: clip.fileName, mimeType: clip.mimeType,
                               importMetadata: metadata, thumbnailBase64: clip.thumbnailBase64)
        } catch PhotoExportError.noPairedVideo {
            return nil
        } catch {
            logger.warning("Live Photo motion for \(identifier, privacy: .public) not uploaded: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Library route

    private func loadFromLibrary(identifier: String) async throws -> PickedMedia {
        let export = try await exporter.exportData(for: identifier, includeVideos: true,
                                                   networkAccessAllowed: true)
        let metadata = assetDates(identifier).map {
            DriveImportMetadata(createdAt: $0.created,
                                updatedAt: $0.modified ?? $0.created,
                                importSource: Self.importSource(assetIdentifier: identifier))
        }
        return PickedMedia(data: export.data, fileName: export.fileName, mimeType: export.mimeType,
                           importMetadata: metadata, thumbnailBase64: export.thumbnailBase64)
    }

    // MARK: Provider route

    private func loadFromProvider(_ item: PickedItem) async throws -> PickedMedia {
        guard let typeIdentifier = Self.preferredTypeIdentifier(item.registeredTypeIdentifiers),
              let type = UTType(typeIdentifier) else {
            throw PickedMediaError.unsupportedItem
        }
        let url = try await item.loadFile(forTypeIdentifier: typeIdentifier)
        // `loadFile` copies into a directory of its own; take the whole directory with it.
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let isMovie = type.conforms(to: .movie)
        let captured: Date? = isMovie ? await Self.movieCreationDate(at: url)
                                      : Self.exifCaptureDate(at: url)
        // A cover has to come from the file while it is on disk; see `PhotoExport.thumbnailBase64`.
        let thumbnail = isMovie ? await ThumbnailGenerator.coverThumbnailBase64(forVideoAt: url) : nil
        // Not memory-mapped: the file is deleted on the way out, and the bytes outlive it.
        let data = try Data(contentsOf: url)

        let metadata = captured.map {
            DriveImportMetadata(createdAt: $0, updatedAt: $0,
                                importSource: Self.importSource(assetIdentifier: item.assetIdentifier))
        }
        return PickedMedia(
            data: data,
            fileName: Self.fileName(suggested: item.suggestedName, type: type,
                                    fallbackDate: captured ?? now()),
            mimeType: type.preferredMIMEType ?? "application/octet-stream",
            importMetadata: metadata,
            thumbnailBase64: thumbnail
        )
    }

    // MARK: Rules (static, so tests can pin them)

    /// The provenance a manual upload records. Distinct from photo sync's `photo-sync:` prefix,
    /// which the date-repair pass treats as "already repaired".
    static func importSource(assetIdentifier: String?) -> String {
        guard let assetIdentifier, !assetIdentifier.isEmpty else { return "photo-upload" }
        return "photo-upload:\(assetIdentifier)"
    }

    /// The first representation that is a single image or movie file, in the provider's order
    /// (which is fidelity order: a HEIC original before its JPEG rendering).
    ///
    /// A Live Photo also registers `com.apple.live-photo-bundle`, a directory holding the still
    /// and the clip. It is skipped here: the motion comes through the library route, which can
    /// name the clip after its still and date it.
    static func preferredTypeIdentifier(_ identifiers: [String]) -> String? {
        identifiers.first { identifier in
            guard identifier != "com.apple.live-photo-bundle",
                  let type = UTType(identifier),
                  type != .livePhoto else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }
    }

    /// `IMG_1234` → `IMG_1234.heic`; a name that already carries an extension of `type` is kept
    /// as it is; no name at all → the exporter's `IMG_<yyyyMMdd_HHmmss>` fallback.
    static func fileName(suggested: String?, type: UTType, fallbackDate: Date) -> String {
        let ext = type.preferredFilenameExtension ?? "bin"
        // The shared rule (#49); only the fallback is this path's own.
        return UploadFileNaming.name(suggested: suggested, fileExtension: ext, fallbackStem: {
            (PHKitAssetExporter.fallbackFileName(creationDate: fallbackDate, ext: ext) as NSString)
                .deletingPathExtension
        })
    }

    /// EXIF `DateTimeOriginal`, honouring `OffsetTimeOriginal` when the camera wrote one and
    /// reading it as device-local time when it didn't, which is what a camera's clock means.
    static func exifCaptureDate(at url: URL, timeZone: TimeZone = .current) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let stamp = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) else { return nil }
        let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        return parseExifDate(stamp, offset: offset, defaultTimeZone: timeZone)
    }

    /// `2019:07:04 10:30:00` plus an optional `+02:00`.
    static func parseExifDate(_ stamp: String, offset: String?, defaultTimeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? defaultTimeZone
        return formatter.date(from: stamp.trimmingCharacters(in: .whitespaces))
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let parts = trimmed.dropFirst().split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    /// A movie's QuickTime creation date, which the iPhone camera writes in UTC.
    static func movieCreationDate(at url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }
}

// MARK: - Import metadata fallback

enum PickedMediaUpload {
    /// Applies `metadata` with `PATCH /import-metadata` when the server didn't keep the dates sent
    /// with the upload, the same fallback photo sync uses for an older server.
    ///
    /// Never throws: the file is already uploaded, and a wrong date isn't worth failing it over.
    static func stampIfNeeded(result: UploadResult, metadata: DriveImportMetadata?,
                              stamp: ((String, DriveImportMetadata) async throws -> Void)?,
                              logger: Logger) async {
        guard let metadata, result.importSource != metadata.importSource, let stamp else { return }
        do {
            try await stamp(result.id, metadata)
        } catch {
            logger.warning("import-metadata patch failed for \(result.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - CameraCaptureEncoder

/// Writes a camera capture with the metadata the camera recorded.
///
/// `UIImagePickerController` hands back a decoded `UIImage` and never the file, so a re-encode
/// can't be avoided here, but the EXIF can be kept: the capture's `mediaMetadata` (date, GPS when
/// location is on, lens, exposure) is written back into the new file, which `jpegData` dropped.
enum CameraCaptureEncoder {

    static func encode(image: UIImage, metadata: [String: Any]?, capturedAt: Date,
                       preferHEIC: Bool = true) throws -> PickedMedia {
        guard let cgImage = image.cgImage else { throw PickedMediaError.encodingFailed }

        var properties = metadata ?? [:]
        // The pixels are stored as the sensor read them; the orientation tag is what turns them.
        properties[kCGImagePropertyOrientation as String] =
            CGImagePropertyOrientation(image.imageOrientation).rawValue
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.9

        let candidates: [UTType] = preferHEIC ? [.heic, .jpeg] : [.jpeg]
        for type in candidates {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, type.identifier as CFString, 1, nil
            ) else { continue }   // No HEIC encoder (some simulators): fall through to JPEG.
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            let ext = type == .heic ? "heic" : "jpg"
            return PickedMedia(
                data: output as Data,
                fileName: PHKitAssetExporter.fallbackFileName(creationDate: capturedAt, ext: ext),
                mimeType: type.preferredMIMEType ?? "image/jpeg",
                // Captured moments ago: the upload's own date is the right one.
                importMetadata: nil
            )
        }
        throw PickedMediaError.encodingFailed
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:            self = .up
        case .upMirrored:    self = .upMirrored
        case .down:          self = .down
        case .downMirrored:  self = .downMirrored
        case .left:          self = .left
        case .leftMirrored:  self = .leftMirrored
        case .right:         self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default:    self = .up
        }
    }
}
