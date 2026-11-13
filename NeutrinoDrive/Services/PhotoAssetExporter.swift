import Foundation
import Photos
import UniformTypeIdentifiers
import os.log

// MARK: - PhotoAssetProviding

/// Abstraction over `PHAsset` so unit tests can supply fakes — `PHAsset` cannot be
/// constructed directly in a test target.
protocol PhotoAssetProviding {
    var localIdentifier: String { get }
    var creationDate: Date? { get }
    /// When the picture was last edited. Sent as the uploaded file's `updatedAt` so a photo
    /// retouched years after it was taken keeps both dates rather than collapsing onto one.
    var modificationDate: Date? { get }
    var mediaType: PHAssetMediaType { get }
    /// `.photoLive` is what marks a Live Photo, whose motion is queued beside it (#42).
    var mediaSubtypes: PHAssetMediaSubtype { get }
}

extension PhotoAssetProviding {
    /// Test fakes describe plain photos unless they say otherwise. `PHAsset` has its own.
    var mediaSubtypes: PHAssetMediaSubtype { [] }
}

extension PHAsset: PhotoAssetProviding {}

// MARK: - PhotoAssetExporting

/// Resolves a `PHAsset.localIdentifier` to exportable bytes. The real implementation talks
/// to `PHImageManager`/`PHAssetResourceManager`; tests inject a fake that returns canned data
/// instantly, without touching PhotoKit.
protocol PhotoAssetExporting {
    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport
    /// A Live Photo's paired video, unmodified, named after its still (`IMG_1234.HEIC` →
    /// `IMG_1234.MOV`). Throws ``PhotoExportError/noPairedVideo`` for an asset that has none.
    func exportPairedVideo(for identifier: String,
                           networkAccessAllowed: Bool) async throws -> PhotoExport
}

extension PhotoAssetExporting {
    /// Fakes that predate Live Photo motion have none to give.
    func exportPairedVideo(for identifier: String,
                           networkAccessAllowed: Bool) async throws -> PhotoExport {
        throw PhotoExportError.noPairedVideo
    }

    /// The export for a queue entry: the asset itself, or its motion for a `#motion` entry.
    func export(entryID: String, includeVideos: Bool,
                networkAccessAllowed: Bool) async throws -> PhotoExport {
        let (assetID, isMotion) = PhotoSyncRules.parseEntryID(entryID)
        if isMotion {
            return try await exportPairedVideo(for: assetID, networkAccessAllowed: networkAccessAllowed)
        }
        return try await exportData(for: assetID, includeVideos: includeVideos,
                                    networkAccessAllowed: networkAccessAllowed)
    }
}

struct PhotoExport {
    let data: Data
    let fileName: String
    let mimeType: String
    /// A cover thumbnail the exporter was able to make more cheaply than the uploader could.
    ///
    /// Only videos set it. An image's cover comes from the same bytes being uploaded, so
    /// `E2EEUploader` derives it and nothing is saved by doing it earlier; a video's has to come
    /// from a file on disk, and the exporter is the one place in the pipeline that already has
    /// one — deriving it downstream would mean writing a second copy of the whole clip.
    ///
    /// Declared last with a default so the memberwise initialiser stays source-compatible with
    /// the fakes in `PhotoSyncServiceTests`.
    var thumbnailBase64: String? = nil
}

enum PhotoExportError: LocalizedError {
    case assetNotFound
    case videoExcluded
    case exportFailed
    /// The original is in iCloud only, and the export was not allowed to download it.
    ///
    /// Only an export with `networkAccessAllowed: false` ends this way. The Photos extension
    /// exports like that and asks the system to download the original instead (see
    /// `PhotoUploadExtensionRunner`), so it is not a failure of the photo.
    case notDownloaded
    /// A `#motion` entry whose asset is not, or is no longer, a Live Photo with a clip — the
    /// user turned Live off, or the clip was never kept. Nothing to upload, not a failure.
    case noPairedVideo

    var errorDescription: String? {
        switch self {
        case .assetNotFound: return "The photo could not be found in the library."
        case .videoExcluded: return "Video sync is turned off."
        case .exportFailed:  return "The photo could not be read for upload."
        case .notDownloaded: return "The photo is in iCloud and has not been downloaded yet."
        case .noPairedVideo: return "This photo has no Live Photo motion."
        }
    }
}

// MARK: - PHKitAssetExporter

/// Production `PhotoAssetExporting`. Images export via `requestImageDataAndOrientation`
/// (current/edited rendition, original bytes — no transcoding). Videos export via
/// `PHAssetResourceManager.writeData(for:toFile:)` to a temp file (never held fully in
/// memory) and are read back as `Data`. A Live Photo's still comes from `exportData`, and its
/// paired video from ``exportPairedVideo(for:networkAccessAllowed:)`` as a separate upload.
final class PHKitAssetExporter: PhotoAssetExporting {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "PHKitAssetExporter")

    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoExportError.assetNotFound
        }

        if asset.mediaType == .video {
            guard includeVideos else { throw PhotoExportError.videoExcluded }
            return try await exportVideo(asset: asset, networkAccessAllowed: networkAccessAllowed)
        }
        return try await exportImage(asset: asset, networkAccessAllowed: networkAccessAllowed)
    }

    // MARK: - Images (and Live Photo stills)

    private func exportImage(asset: PHAsset, networkAccessAllowed: Bool) async throws -> PhotoExport {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first(where: { $0.type == .photo }) ?? resources.first
        let fallbackName = Self.fallbackFileName(for: asset, ext: "jpg")

        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.isNetworkAccessAllowed = networkAccessAllowed
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: Self.isNetworkRequired(error) ? PhotoExportError.notDownloaded : error)
                    return
                }
                guard let data else {
                    // Without network access an iCloud-only original comes back as no data,
                    // flagged in the info dictionary rather than as an error.
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    continuation.resume(throwing: inCloud && !networkAccessAllowed
                                        ? PhotoExportError.notDownloaded
                                        : PhotoExportError.exportFailed)
                    return
                }
                let mimeType = dataUTI.flatMap { UTType($0)?.preferredMIMEType } ?? "image/jpeg"
                let fileName = primary?.originalFilename ?? fallbackName
                continuation.resume(returning: PhotoExport(data: data, fileName: fileName, mimeType: mimeType))
            }
        }
    }

    // MARK: - Videos

    private func exportVideo(asset: PHAsset, networkAccessAllowed: Bool) async throws -> PhotoExport {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video }) ?? resources.first else {
            throw PhotoExportError.exportFailed
        }
        let fileName = resource.originalFilename.isEmpty
            ? Self.fallbackFileName(for: asset, ext: "mov")
            : resource.originalFilename
        return try await exportMovie(resource, fileName: fileName,
                                     networkAccessAllowed: networkAccessAllowed)
    }

    // MARK: - Live Photo motion

    func exportPairedVideo(for identifier: String,
                           networkAccessAllowed: Bool) async throws -> PhotoExport {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw PhotoExportError.assetNotFound
        }
        guard asset.mediaSubtypes.contains(.photoLive),
              let clip = Self.pairedVideoResource(for: asset) else {
            throw PhotoExportError.noPairedVideo
        }
        let stillName = Self.uploadedFileName(for: asset)
        let fileName = Self.pairedVideoFileName(stillName: stillName, videoName: clip.originalFilename)
        // Written out byte for byte: the clip's `com.apple.quicktime.content.identifier` and
        // still-image-time track are what pair it with the still again later.
        return try await exportMovie(clip, fileName: fileName, networkAccessAllowed: networkAccessAllowed)
    }

    /// The clip to upload for a Live Photo: the edited one when there is one, so it matches the
    /// edited still `exportImage` uploads (`version = .current`), otherwise the original.
    static func pairedVideoResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: { $0.type == .fullSizePairedVideo })
            ?? resources.first(where: { $0.type == .pairedVideo })
    }

    /// The clip is named after its still, never after itself: the shared stem is how a still and
    /// its clip are paired when nothing else links them (Apple's own export, Google Takeout and
    /// the web's `pairMotionPhotos` all rely on it). `IMG_1234.HEIC` + `IMG_1234.MOV` →
    /// `IMG_1234.MOV`; a clip PhotoKit named differently (an edited `FullSizeRender.mov`) still
    /// gets the still's stem.
    static func pairedVideoFileName(stillName: String, videoName: String) -> String {
        let stem = (stillName as NSString).deletingPathExtension
        let ext = (videoName as NSString).pathExtension
        return "\(stem).\(ext.isEmpty ? "MOV" : ext)"
    }

    /// The name an asset is uploaded under: its primary resource's `originalFilename`, or the
    /// dated fallback. `PHKitAssetMetadataProvider` matches files back to assets by exactly this.
    static func uploadedFileName(for asset: PHAsset) -> String {
        let isVideo = asset.mediaType == .video
        if let name = primaryResource(for: asset)?.originalFilename, !name.isEmpty { return name }
        return fallbackFileName(creationDate: asset.creationDate, ext: isVideo ? "mov" : "jpg")
    }

    /// The name a queue entry is uploaded under: the asset's, or for a `#motion` entry its clip's.
    /// `nil` when the asset is gone, or a `#motion` entry's asset has no clip.
    static func uploadedFileName(forEntryID entryID: String, asset: PHAsset) -> String? {
        guard PhotoSyncRules.parseEntryID(entryID).isMotion else { return uploadedFileName(for: asset) }
        guard let clip = pairedVideoResource(for: asset) else { return nil }
        return pairedVideoFileName(stillName: uploadedFileName(for: asset), videoName: clip.originalFilename)
    }

    // MARK: - Movies

    /// Writes `resource` to a temp file, takes a cover from it, and reads it back.
    private func exportMovie(_ resource: PHAssetResource, fileName: String,
                             networkAccessAllowed: Bool) async throws -> PhotoExport {
        let mimeType = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "video/quicktime"

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((fileName as NSString).pathExtension)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = networkAccessAllowed

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: Self.isNetworkRequired(error) ? PhotoExportError.notDownloaded : error)
                } else {
                    continuation.resume()
                }
            }
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }
        // Taken here, while the clip is still on disk and before the `defer` above reclaims it.
        // `AVFoundation` reads poster frames from files, so the alternative is spilling the whole
        // video back out to a second temp file downstream — up to half a gigabyte of extra writes
        // (see `maxAssetSizeBytes`), in a background drain that is racing an expiry.
        let thumbnailBase64 = await ThumbnailGenerator.coverThumbnailBase64(forVideoAt: tempURL)
        let data = try Data(contentsOf: tempURL)
        return PhotoExport(data: data, fileName: fileName, mimeType: mimeType,
                           thumbnailBase64: thumbnailBase64)
    }

    // MARK: - Resources

    /// The resource an asset's upload is made from: the still for a photo or Live Photo, the
    /// clip for a video. The Photos extension asks the system to download this one when the
    /// export finds it is in iCloud only.
    static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        return resources.first(where: { $0.type == preferred }) ?? resources.first
    }

    /// The resource a queue entry uploads: ``primaryResource(for:)``, or the clip for a
    /// `#motion` entry. What the Photos extension sizes, and asks iOS to download.
    static func uploadResource(forEntryID entryID: String) -> PHAssetResource? {
        let (assetID, isMotion) = PhotoSyncRules.parseEntryID(entryID)
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            return nil
        }
        return isMotion ? pairedVideoResource(for: asset) : primaryResource(for: asset)
    }

    /// Whether PhotoKit refused because the bytes are not on the device and fetching them
    /// needs the network.
    private static func isNetworkRequired(_ error: Error) -> Bool {
        (error as? PHPhotosError)?.code == .networkAccessRequired
    }

    // MARK: - Naming

    private static func fallbackFileName(for asset: PHAsset, ext: String) -> String {
        fallbackFileName(creationDate: asset.creationDate, ext: ext)
    }

    /// The name an asset with no usable `PHAssetResource` is uploaded under.
    ///
    /// Not private: `PHKitAssetMetadataProvider` has to reproduce the *same* name to match an
    /// uploaded file back to its asset, and a second copy of this format string is a
    /// divergence nobody would notice until the repair pass reported a photo missing.
    static func fallbackFileName(creationDate: Date?, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: creationDate ?? Date())
        return "IMG_\(stamp).\(ext)"
    }
}
