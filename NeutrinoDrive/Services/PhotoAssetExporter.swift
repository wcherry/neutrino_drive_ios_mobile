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
}

extension PHAsset: PhotoAssetProviding {}

// MARK: - PhotoAssetExporting

/// Resolves a `PHAsset.localIdentifier` to exportable bytes. The real implementation talks
/// to `PHImageManager`/`PHAssetResourceManager`; tests inject a fake that returns canned data
/// instantly, without touching PhotoKit.
protocol PhotoAssetExporting {
    func exportData(for identifier: String, includeVideos: Bool,
                    networkAccessAllowed: Bool) async throws -> PhotoExport
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

    var errorDescription: String? {
        switch self {
        case .assetNotFound: return "The photo could not be found in the library."
        case .videoExcluded: return "Video sync is turned off."
        case .exportFailed:  return "The photo could not be read for upload."
        case .notDownloaded: return "The photo is in iCloud and has not been downloaded yet."
        }
    }
}

// MARK: - PHKitAssetExporter

/// Production `PhotoAssetExporting`. Images export via `requestImageDataAndOrientation`
/// (current/edited rendition, original bytes — no transcoding). Videos export via
/// `PHAssetResourceManager.writeData(for:toFile:)` to a temp file (never held fully in
/// memory) and are read back as `Data`. Live Photos upload the still image resource only —
/// the paired video resource is intentionally skipped for MVP.
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
