import Foundation
import Photos
import os.log

// "Add Live Photo Motion" (#42, part 2): queues the paired video of Live Photos that photo sync
// backed up as stills only, before it kept motion. The clips only exist on this device, so the
// pass has to run here. It doesn't upload anything itself; it enqueues `#motion` entries and the
// ordinary drain sends them, under the same Wi-Fi, charging, retry and background rules as any
// photo.

// MARK: - LivePhotoMotionAsset

/// What the pass needs to know about one asset still on the device.
enum LivePhotoMotionAsset: Equatable {
    /// Not a Live Photo, or one with no clip — nothing to add.
    case notLive
    case live(LivePhotoClip)
}

struct LivePhotoClip: Equatable {
    let creationDate: Date
    let modificationDate: Date?
    /// The name the still was uploaded under — how a still is found in the folder when the
    /// ledger has no file id for it.
    let stillName: String
    /// The name the clip would be uploaded under (the still's stem).
    let clipName: String
    /// `nil` when PhotoKit can't say without reading the clip (before iOS 27).
    let clipBytes: Int64?
}

/// Resolves asset identifiers to ``LivePhotoMotionAsset``s. An identifier missing from the
/// result is not on this device any more. A protocol so the pass is testable without PhotoKit.
protocol LivePhotoMotionAssetProviding {
    func assets(forIdentifiers identifiers: [String]) -> [String: LivePhotoMotionAsset]
}

struct PHKitLivePhotoMotionAssetProvider: LivePhotoMotionAssetProviding {
    func assets(forIdentifiers identifiers: [String]) -> [String: LivePhotoMotionAsset] {
        var found: [String: LivePhotoMotionAsset] = [:]
        for chunk in stride(from: 0, to: identifiers.count, by: 500) {
            let slice = Array(identifiers[chunk..<min(chunk + 500, identifiers.count)])
            PHAsset.fetchAssets(withLocalIdentifiers: slice, options: nil).enumerateObjects { asset, _, _ in
                guard asset.mediaSubtypes.contains(.photoLive),
                      let created = asset.creationDate,
                      let clip = PHKitAssetExporter.pairedVideoResource(for: asset) else {
                    found[asset.localIdentifier] = .notLive
                    return
                }
                let stillName = PHKitAssetExporter.uploadedFileName(for: asset)
                var bytes: Int64?
                if #available(iOS 27, *), let size = clip.dataSize { bytes = Int64(size) }
                found[asset.localIdentifier] = .live(LivePhotoClip(
                    creationDate: created,
                    modificationDate: asset.modificationDate,
                    stillName: stillName,
                    clipName: PHKitAssetExporter.pairedVideoFileName(stillName: stillName,
                                                                     videoName: clip.originalFilename),
                    clipBytes: bytes
                ))
            }
        }
        return found
    }
}

// MARK: - Report and state

/// The outcome of one pass, in the terms the user is shown. Every Live Photo the pass looked at
/// lands in exactly one bucket.
struct LivePhotoMotionBackfillReport: Codable, Equatable {
    /// Clips queued for upload.
    var queued = 0
    /// A clip named after the still is already in the folder — recorded, not uploaded again.
    var alreadyHadMotion = 0
    /// The still is no longer in the backup folder: deleted or moved in Drive, or backed up to a
    /// folder used before the destination was renamed. Its motion is not added, which would
    /// bring back half of a photo the user removed.
    var notInBackupFolder = 0
    /// Backed up from this device, but no longer in its photo library. Not necessarily Live
    /// Photos — there is no way left to tell.
    var notOnDevice = 0
    var finishedAt = Date()

    var summary: String {
        var parts = ["\(queued) queued"]
        if alreadyHadMotion > 0  { parts.append("\(alreadyHadMotion) already had motion") }
        if notInBackupFolder > 0 { parts.append("\(notInBackupFolder) no longer in the backup folder") }
        if notOnDevice > 0       { parts.append("\(notOnDevice) not on this device") }
        return parts.joined(separator: ", ")
    }
}

enum LivePhotoMotionBackfillState: Equatable {
    case idle
    case checking
    /// Found work; waiting for the user to confirm the upload.
    case awaitingConfirmation(count: Int, estimatedBytes: Int64)
    case finished(LivePhotoMotionBackfillReport)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .awaitingConfirmation: return true
        default: return false
        }
    }
}

// MARK: - Planner

/// Decides, from the queue, the device's assets and the backup folder, which Live Photos get
/// their motion queued and which of the other buckets each one is. Pure, so the rules are tested
/// without PhotoKit or a network.
enum LivePhotoMotionBackfillPlanner {

    /// A clip whose size PhotoKit can't tell is counted at this, for the estimate only.
    static let typicalClipBytes: Int64 = 3_000_000

    struct Enqueue: Equatable {
        let entryID: String
        let creationDate: Date
        let modificationDate: Date?
    }

    struct Plan: Equatable {
        var enqueue: [Enqueue] = []
        /// `#motion` entry id → the Drive file already holding that clip.
        var existingClips: [String: String] = [:]
        var notInBackupFolder = 0
        var notOnDevice = 0
        var estimatedBytes: Int64 = 0

        var report: LivePhotoMotionBackfillReport {
            LivePhotoMotionBackfillReport(queued: enqueue.count, alreadyHadMotion: existingClips.count,
                                          notInBackupFolder: notInBackupFolder, notOnDevice: notOnDevice)
        }
    }

    /// The stills to consider: every asset the queue knows (uploaded, waiting or failed) whose
    /// motion it doesn't know yet.
    static func candidateIdentifiers(in queue: PhotoSyncQueue) -> [String] {
        let known = Set(queue.completed.keys)
            .union(queue.pending.map(\.id))
            .union(queue.failed.map(\.id))
        return known.filter { id in
            !PhotoSyncRules.parseEntryID(id).isMotion
                && !queue.contains(id: PhotoSyncRules.motionEntryID(forAssetIdentifier: id))
        }
        .sorted()
    }

    /// - Parameter folderFiles: the backup folder's files, or `nil` when there is no folder to
    ///   check against (none resolved yet). Then nothing counts as removed from Drive, and no
    ///   existing clip is found.
    static func plan(queue: PhotoSyncQueue, assets: [String: LivePhotoMotionAsset],
                     folderFiles: [DriveFolderFile]?) -> Plan {
        let fileIDs = Set(folderFiles?.map(\.id) ?? [])
        var filesByName: [String: String] = [:]
        for file in folderFiles ?? [] where filesByName[file.name.lowercased()] == nil {
            filesByName[file.name.lowercased()] = file.id
        }

        var plan = Plan()
        for id in candidateIdentifiers(in: queue) {
            guard let asset = assets[id] else {
                // Only uploaded stills are worth reporting; one that never left is just gone.
                if queue.completed[id] != nil { plan.notOnDevice += 1 }
                continue
            }
            guard case .live(let clip) = asset else { continue }

            if folderFiles != nil, let completed = queue.completed[id] {
                let stillPresent = completed.fileID.map(fileIDs.contains)
                    ?? (filesByName[clip.stillName.lowercased()] != nil)
                guard stillPresent else {
                    plan.notInBackupFolder += 1
                    continue
                }
            }

            let motionID = PhotoSyncRules.motionEntryID(forAssetIdentifier: id)
            if let existing = filesByName[clip.clipName.lowercased()] {
                plan.existingClips[motionID] = existing
                continue
            }
            plan.enqueue.append(Enqueue(entryID: motionID, creationDate: clip.creationDate,
                                        modificationDate: clip.modificationDate))
            plan.estimatedBytes += clip.clipBytes ?? typicalClipBytes
        }
        return plan
    }
}

// MARK: - PhotoSyncService + motion backfill

extension PhotoSyncService {

    /// Checks which already-backed-up Live Photos are missing their motion, and asks to confirm.
    ///
    /// Lists the whole backup folder once, to leave out stills the user removed from Drive (adding
    /// their motion would bring back half a photo) and clips already there (`IMG_1234.MOV` next
    /// to `IMG_1234.HEIC`). The listing has no `importSource`, so an existing clip is recognised
    /// by its name. Nothing is uploaded until ``confirmLivePhotoMotionBackfill()``.
    func checkLivePhotoMotionBackfill() async {
        guard !motionBackfillState.isBusy else { return }
        guard keepLivePhotoMotion else {
            motionBackfillState = .failed("Turn on Keep Live Photo Motion first.")
            return
        }
        motionBackfillState = .checking
        reloadQueue()

        var folderFiles: [DriveFolderFile]?
        if let folderID = photoFolderID {
            guard let folderPageLister else {
                motionBackfillState = .failed("Photo sync is not ready yet. Try again in a moment.")
                return
            }
            await tokenRefresher?()
            guard hasAccessTokenProvider() else {
                motionBackfillState = .failed("Sign in to add Live Photo motion.")
                return
            }
            do {
                folderFiles = try await listWholeFolder(folderID, using: folderPageLister)
            } catch {
                motionLogger.error("motion backfill listing failed: \(error, privacy: .public)")
                motionBackfillState = .failed("Could not read the backup folder: \(error.localizedDescription)")
                return
            }
        }

        let candidates = LivePhotoMotionBackfillPlanner.candidateIdentifiers(in: queueSnapshot)
        let assets = motionAssetProvider.assets(forIdentifiers: candidates)
        let plan = LivePhotoMotionBackfillPlanner.plan(queue: queueSnapshot, assets: assets,
                                                       folderFiles: folderFiles)
        pendingMotionPlan = plan
        if plan.enqueue.isEmpty {
            await confirmLivePhotoMotionBackfill()
        } else {
            motionBackfillState = .awaitingConfirmation(count: plan.enqueue.count,
                                                        estimatedBytes: plan.estimatedBytes)
        }
    }

    /// Queues the checked plan's clips, records the ones already in Drive, and starts a drain.
    func confirmLivePhotoMotionBackfill() async {
        guard let plan = pendingMotionPlan else { return }
        pendingMotionPlan = nil
        mutateQueue { queue in
            for (entryID, fileID) in plan.existingClips {
                queue.markCompleted(id: entryID, fileID: fileID)
            }
            for item in plan.enqueue {
                queue.enqueue(id: item.entryID, creationDate: item.creationDate,
                              modificationDate: item.modificationDate)
            }
        }
        var report = plan.report
        report.finishedAt = Date()
        lastMotionBackfill = report
        motionBackfillState = .finished(report)
        motionLogger.info("motion backfill: \(report.summary, privacy: .public)")
        if !plan.enqueue.isEmpty {
            scheduleBackgroundTask()
            await drain(ignoringPowerConstraint: false)
        }
    }

    func cancelLivePhotoMotionBackfill() {
        pendingMotionPlan = nil
        motionBackfillState = .idle
    }

    private func listWholeFolder(
        _ folderID: String,
        using lister: (String, Int, Int) async throws -> [DriveFolderFile]
    ) async throws -> [DriveFolderFile] {
        var files: [DriveFolderFile] = []
        var offset = 0
        while true {
            let page = try await lister(folderID, Self.dateRepairPageSize, offset)
            files += page
            if page.count < Self.dateRepairPageSize { return files }
            offset += Self.dateRepairPageSize
        }
    }

    private var motionLogger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive", category: "LivePhotoMotionBackfill")
    }
}
