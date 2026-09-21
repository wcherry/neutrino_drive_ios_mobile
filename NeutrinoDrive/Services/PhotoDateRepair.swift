import Foundation
import Photos
import os.log

// MARK: - PhotoAssetMetadata

/// What the repair pass needs to know about one asset still on the device: the name it was
/// uploaded under, and the dates the uploaded file should have had.
struct PhotoAssetMetadata: Equatable {
    let localIdentifier: String
    /// `PHAssetResource.originalFilename`, or the exporter's generated fallback — whichever
    /// the upload would have used. Matching depends on reproducing that choice exactly.
    let originalFilename: String
    let creationDate: Date
    let modificationDate: Date?
}

// MARK: - PhotoAssetMetadataProviding

/// Resolves `PHAsset.localIdentifier`s to their filenames and dates.
///
/// A protocol for the same reason `PhotoAssetProviding` is one: `PHAsset` cannot be
/// constructed in a test target, so the repair pass would otherwise be untestable end to end.
protocol PhotoAssetMetadataProviding {
    func metadata(forIdentifiers identifiers: [String]) -> [PhotoAssetMetadata]
}

// MARK: - PHKitAssetMetadataProvider

/// Production `PhotoAssetMetadataProviding`.
///
/// Picks the resource the *exporter* would have picked — `.photo` for an image, `.video` for
/// a clip — and falls back to the same generated name. Any divergence here shows up as a
/// photo the repair pass reports as "not on this device" while it is sitting right there.
struct PHKitAssetMetadataProvider: PhotoAssetMetadataProviding {

    func metadata(forIdentifiers identifiers: [String]) -> [PhotoAssetMetadata] {
        guard !identifiers.isEmpty else { return [] }
        var found: [PhotoAssetMetadata] = []
        // PhotoKit copes with a large identifier list, but a year of camera roll is thousands
        // of assets and each one costs a resource lookup; chunking keeps the peak bounded.
        for chunk in stride(from: 0, to: identifiers.count, by: 500) {
            let slice = Array(identifiers[chunk..<min(chunk + 500, identifiers.count)])
            let result = PHAsset.fetchAssets(withLocalIdentifiers: slice, options: nil)
            result.enumerateObjects { asset, _, _ in
                guard let created = asset.creationDate else { return }
                found.append(PhotoAssetMetadata(
                    localIdentifier: asset.localIdentifier,
                    originalFilename: Self.uploadedFileName(for: asset),
                    creationDate: created,
                    modificationDate: asset.modificationDate
                ))
            }
        }
        return found
    }

    /// The name `PHKitAssetExporter` would have uploaded this asset under.
    static func uploadedFileName(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        let isVideo = asset.mediaType == .video
        let wanted: PHAssetResourceType = isVideo ? .video : .photo
        let primary = resources.first(where: { $0.type == wanted }) ?? resources.first
        if let name = primary?.originalFilename, !name.isEmpty { return name }
        return PHKitAssetExporter.fallbackFileName(creationDate: asset.creationDate,
                                                   ext: isVideo ? "mov" : "jpg")
    }
}

// MARK: - PhotoDateRepairReport

/// The outcome of one repair pass, in the terms the user is shown.
///
/// Every file the pass looked at lands in exactly one bucket, so the five add up to the
/// number examined. That is the point: a pass that quietly did nothing to most of a folder
/// should say so rather than reporting only its successes.
struct PhotoDateRepairReport: Codable, Equatable {
    /// Files given their capture date.
    var repaired = 0
    /// Files whose date already matched the asset — the reason a second run is cheap and a
    /// suspended run can simply be started again.
    var alreadyCorrect = 0
    /// Filenames claimed by more than one asset (`IMG_0001.HEIC` after a counter reset).
    /// Left alone rather than guessed at.
    var ambiguous = 0
    /// No asset on this device carries that filename — deleted since, uploaded from another
    /// device, or renamed by the server to avoid a collision.
    var notOnDevice = 0
    /// The patch was attempted and the server refused it, after backoff.
    var failed = 0
    var finishedAt = Date()

    var examined: Int { repaired + alreadyCorrect + ambiguous + notOnDevice + failed }

    /// One line, in plain words, for the Settings row.
    var summary: String {
        var parts = ["\(repaired) repaired"]
        if alreadyCorrect > 0 { parts.append("\(alreadyCorrect) already correct") }
        if ambiguous > 0      { parts.append("\(ambiguous) ambiguous") }
        if notOnDevice > 0    { parts.append("\(notOnDevice) not on this device") }
        if failed > 0         { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - PhotoDateRepairState

enum PhotoDateRepairState: Equatable {
    case idle
    case running(examined: Int)
    case finished(PhotoDateRepairReport)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - PhotoDateRepairPlanner

/// Decides, for a page of Drive files and the assets still on the device, which files need a
/// date patch and which of the other three things each remaining file is.
///
/// Pure and static so the matching rules — the part that can silently be wrong — are testable
/// without a network, a photo library, or a running drain.
enum PhotoDateRepairPlanner {

    struct Patch: Equatable {
        let fileID: String
        let metadata: DriveImportMetadata
    }

    struct Plan: Equatable {
        var patches: [Patch] = []
        var alreadyCorrect = 0
        var ambiguous = 0
        var notOnDevice = 0
    }

    /// How far apart a file's stored date and its asset's capture date may be and still count
    /// as the same date.
    ///
    /// Not zero, because the patch sends whole seconds (RFC 3339 without a fractional part)
    /// while `PHAsset.creationDate` carries sub-second precision, so a correctly repaired file
    /// never reads back exactly equal. Two seconds is far inside the gap this is
    /// distinguishing — a wrong date here is wrong by months or years, never by a second.
    static let dateTolerance: TimeInterval = 2

    static func plan(files: [DriveFolderFile],
                     assets: [PhotoAssetMetadata],
                     tolerance: TimeInterval = dateTolerance) -> Plan {
        var byName: [String: [PhotoAssetMetadata]] = [:]
        for asset in assets {
            byName[asset.originalFilename, default: []].append(asset)
        }

        var plan = Plan()
        for file in files {
            let matches = byName[file.name] ?? []
            guard !matches.isEmpty else {
                plan.notOnDevice += 1
                continue
            }
            guard matches.count == 1, let asset = matches.first else {
                plan.ambiguous += 1
                continue
            }
            if let createdAt = file.createdAt,
               abs(createdAt.timeIntervalSince(asset.creationDate)) <= tolerance {
                plan.alreadyCorrect += 1
                continue
            }
            plan.patches.append(Patch(
                fileID: file.id,
                metadata: DriveImportMetadata(
                    createdAt: asset.creationDate,
                    updatedAt: asset.modificationDate ?? asset.creationDate,
                    importSource: PhotoSyncService.importSource(forAssetIdentifier: asset.localIdentifier)
                )
            ))
        }
        return plan
    }
}

// MARK: - PhotoSyncService + repair

extension PhotoSyncService {

    /// How many files one folder-listing request asks for.
    static let dateRepairPageSize = 200

    /// Delays between attempts at a single patch the server pushed back on (429/5xx).
    static let dateRepairBackoff: [TimeInterval] = [1, 4, 16]

    /// One-time pass that gives already-uploaded photos the date they were taken.
    ///
    /// ## Why this has to run on the device
    ///
    /// A server-side backfill is impossible: photo content is end-to-end encrypted, so the
    /// backend can never read EXIF, and no capture date was ever stored for these files. The
    /// only place the true dates still exist is the photo library on this phone.
    ///
    /// ## How a file is matched
    ///
    /// By filename — the same name the upload used (`PHAssetResource.originalFilename`). A
    /// name claimed by more than one asset is left alone and counted rather than guessed at,
    /// because getting it wrong writes a *different* wrong date over a wrong date and there is
    /// then nothing left to tell the two apart.
    ///
    /// ## Why it is safe to run twice
    ///
    /// A file whose stored date already matches its asset is skipped, so a pass interrupted by
    /// a suspend or a lost network is resumed by simply running it again — no cursor to keep
    /// and no way for a half-finished pass to leave the folder worse than it found it. (Issue
    /// #31 suggested skipping on `importSource` instead; the folder-contents DTO does not
    /// carry that field, and fetching it would cost one extra request per photo for a weaker
    /// version of the same test.)
    ///
    /// ## What it cannot reach
    ///
    /// Photos deleted from the device, uploaded from a different device or from before a
    /// reinstall, and photos the server had to rename to avoid a filename collision. Those are
    /// reported as "not on this device" and keep their wrong dates.
    func repairPhotoDates() async {
        guard !dateRepairState.isRunning else { return }
        guard let folderID = photoFolderID else {
            dateRepairState = .failed("No photo backup folder has been created yet.")
            return
        }
        guard let folderPageLister, let importMetadataStamper else {
            dateRepairState = .failed("Photo sync is not ready yet. Try again in a moment.")
            return
        }

        // The same constraints a drain runs under. A repair pass is thousands of small
        // requests, which is exactly the kind of thing "Wi-Fi only" is set for.
        await tokenRefresher?()
        guard hasAccessTokenProvider() else {
            dateRepairState = .failed("Sign in to repair photo dates.")
            return
        }
        if wifiOnly && (!isOnWiFi || isNetworkExpensive) {
            dateRepairState = .failed("Waiting for Wi-Fi.")
            return
        }
        if whileChargingOnly && batteryStateProvider() == .unplugged {
            dateRepairState = .failed("Waiting to charge.")
            return
        }

        dateRepairState = .running(examined: 0)
        let assets = assetMetadataProvider.metadata(forIdentifiers: completedAssetIdentifiers)
        var report = PhotoDateRepairReport()
        var offset = 0

        while true {
            let page: [DriveFolderFile]
            do {
                page = try await folderPageLister(folderID, Self.dateRepairPageSize, offset)
            } catch {
                repairLogger.error("repairPhotoDates listing failed: \(error, privacy: .public)")
                dateRepairState = .failed("Could not read the backup folder: \(error.localizedDescription)")
                return
            }
            if page.isEmpty { break }

            let plan = PhotoDateRepairPlanner.plan(files: page, assets: assets)
            report.alreadyCorrect += plan.alreadyCorrect
            report.ambiguous      += plan.ambiguous
            report.notOnDevice    += plan.notOnDevice

            for patch in plan.patches {
                if await stampWithBackoff(patch, using: importMetadataStamper) {
                    report.repaired += 1
                } else {
                    report.failed += 1
                }
                dateRepairState = .running(examined: report.examined)
            }
            dateRepairState = .running(examined: report.examined)

            // A short page is the last page. Paging by name keeps that true while the pass
            // runs: the patches rewrite dates, and nothing here renames anything.
            if page.count < Self.dateRepairPageSize { break }
            offset += Self.dateRepairPageSize
        }

        report.finishedAt = Date()
        lastDateRepair = report
        dateRepairState = .finished(report)
        repairLogger.debug("repairPhotoDates finished: \(report.summary, privacy: .public)")
    }

    private var repairLogger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive", category: "PhotoDateRepair")
    }

    /// Applies one patch, retrying the failures that describe a momentary condition rather
    /// than a bad request: 429, 5xx, and a transport error. A 4xx other than 429 will fail
    /// identically however many times it is sent.
    private func stampWithBackoff(
        _ patch: PhotoDateRepairPlanner.Patch,
        using stamp: (String, DriveImportMetadata) async throws -> Void
    ) async -> Bool {
        for attempt in 0...Self.dateRepairBackoff.count {
            do {
                try await stamp(patch.fileID, patch.metadata)
                return true
            } catch {
                guard attempt < Self.dateRepairBackoff.count, Self.isRetryable(error) else {
                    repairLogger.error("""
                        repairPhotoDates patch failed for \(patch.fileID, privacy: .public): \
                        \(error.localizedDescription, privacy: .public)
                        """)
                    return false
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.dateRepairBackoff[attempt] * 1_000_000_000))
            }
        }
        return false
    }

    static func isRetryable(_ error: Error) -> Bool {
        guard let driveError = error as? DriveError else { return false }
        switch driveError {
        case .networkError:
            return true
        case .serverError(let code):
            return code == 408 || code == 429 || code >= 500
        case .notAuthenticated, .decodingError:
            return false
        }
    }
}
