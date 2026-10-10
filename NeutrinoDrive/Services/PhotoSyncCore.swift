import Foundation
import Photos
import os.log

// The part of photo sync that both the app and the Photos background-upload extension compile:
// the settings keys, the identities an upload is filed under, and where the shared state lives.
// Kept free of UIKit, BackgroundTasks and the main actor, which is what lets the extension
// target list this file next to `PhotoSyncQueue.swift` and `E2EEUploader.swift`.

// MARK: - PhotoSyncKeys

/// The `UserDefaults` keys photo sync keeps its settings and progress under.
///
/// In the App Group suite (see ``PhotoSyncDefaults``), because the Photos extension reads the
/// same settings and records the same progress as the app.
enum PhotoSyncKeys {
    static let enabled            = "photoSync.enabled"
    static let folderName         = "photoSync.folderName"
    static let folderID           = "photoSync.folderID"
    static let includeVideos      = "photoSync.includeVideos"
    static let wifiOnly           = "photoSync.wifiOnly"
    static let whileChargingOnly  = "photoSync.whileChargingOnly"
    static let anchorDate         = "photoSync.anchorDate"
    /// How many days *before* the anchor date to reach back into the existing library.
    /// See ``PhotoSyncService/backfillDays``.
    static let backfillDays       = "photoSync.backfillDays"
    /// The earliest creation date a backfill scan has already swept. Stops every launch
    /// from re-enumerating a year of library for assets the queue already knows about.
    static let backfillScannedFrom = "photoSync.backfillScannedFrom"
    static let changeToken        = "photoSync.changeToken"
    static let lastSuccessfulSync = "photoSync.lastSuccessfulSyncDate"
    /// When a `BGTask` last handed us runtime. Separate from `lastSuccessfulSync`: it
    /// records that iOS woke the app *at all*, which is the thing worth knowing when
    /// photos are only moving once the app is opened by hand.
    static let lastBackgroundRun  = "photoSync.lastBackgroundRunDate"
    /// The last completed "Repair Photo Dates" pass, as JSON. Survives a relaunch so the
    /// Settings screen can still say what the pass found.
    static let lastDateRepair     = "photoSync.lastDateRepair"

    /// Every key above, for ``PhotoSyncDefaults/migrate(from:to:)``.
    static let all = [
        enabled, folderName, folderID, includeVideos, wifiOnly, whileChargingOnly, anchorDate,
        backfillDays, backfillScannedFrom, changeToken, lastSuccessfulSync, lastBackgroundRun,
        lastDateRepair,
    ]
}

// MARK: - PhotoSyncDefaults

/// Where photo sync's settings live: the App Group suite, so the Photos extension sees what the
/// Settings screen set.
enum PhotoSyncDefaults {

    /// Set in the shared suite once the settings have been copied out of `.standard`.
    static let migratedKey = "photoSync.migratedToAppGroup"

    /// The App Group suite, with anything an earlier build left in `.standard` copied over the
    /// first time it is asked for. Falls back to `.standard` where the group is unavailable.
    static var shared: UserDefaults {
        let suite = SharedStorage.defaults
        if suite !== UserDefaults.standard {
            migrate(from: .standard, to: suite)
        }
        return suite
    }

    /// Copies every photo sync setting from `old` into `new` once, without overwriting a value
    /// `new` already has. `old` keeps its copy, so a downgrade still finds its settings.
    static func migrate(from old: UserDefaults, to new: UserDefaults) {
        guard !new.bool(forKey: migratedKey) else { return }
        for key in PhotoSyncKeys.all where new.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { new.set(value, forKey: key) }
        }
        new.set(true, forKey: migratedKey)
    }
}

// MARK: - PhotoSyncStorage

/// Where photo sync's files live.
enum PhotoSyncStorage {

    /// The App Group container, where both processes can reach the queue and the run log.
    /// Application Support where the group is unavailable, as in a unit-test host without it.
    static var directory: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStorage.appGroupIdentifier)
            ?? legacyDirectory
    }

    /// Where builds before the Photos extension kept the queue.
    static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}

// MARK: - PhotoSyncRules

/// The identities a photo's upload is filed under. Every process that uploads a photo has to
/// agree on them, which is why they are here rather than on `PhotoSyncService`.
enum PhotoSyncRules {

    /// The provenance string a photo-sync upload records on its Drive file.
    ///
    /// `import_source` means "came from an archive import" elsewhere, and is reused here with
    /// a prefix rather than given a field of its own on the backend — the cheapest correct
    /// path, and one that keeps this whole change client-side. It carries the asset identifier
    /// so a file can always be traced back to the picture it came from.
    static func importSource(forAssetIdentifier identifier: String) -> String {
        "photo-sync:\(identifier)"
    }

    /// The stable upload identity for one asset.
    ///
    /// Photo sync is the path that suspends most — a background drain is suspended by
    /// definition — and it is also the only upload path whose retries are automatic, so it is
    /// the one that most needs a retry to recognise its own interrupted attempt. The asset's
    /// `localIdentifier` is the natural key: one asset is one logical upload, however many
    /// attempts it takes. Shares its shape with the `import_source` stamp on purpose.
    static func uploadID(forAssetIdentifier identifier: String) -> String {
        importSource(forAssetIdentifier: identifier)
    }

    /// The asset a photo-sync blob transfer id belongs to, or `nil` for any other transfer.
    static func assetIdentifier(forTransferID transferID: String) -> String? {
        let prefix = E2EEUploader.blobTransferID(uploadID: uploadID(forAssetIdentifier: ""))
        guard transferID.hasPrefix(prefix) else { return nil }
        return String(transferID.dropFirst(prefix.count))
    }

    /// Returns the identifiers from `assets` that are not already known to `queue` and were
    /// created on/after `anchorDate`, oldest-first.
    static func newIdentifiers(from assets: [PhotoAssetProviding], anchorDate: Date,
                               includeVideos: Bool, queue: PhotoSyncQueue)
    -> [(id: String, creationDate: Date, modificationDate: Date?)] {
        assets
            .filter { includeVideos || $0.mediaType != .video }
            .compactMap { asset -> (String, Date, Date?)? in
                guard let created = asset.creationDate, created >= anchorDate else { return nil }
                guard !queue.contains(id: asset.localIdentifier) else { return nil }
                return (asset.localIdentifier, created, asset.modificationDate)
            }
            .sorted { $0.1 < $1.1 }
    }

    /// Whether `error` will still fail however many times it is retried.
    ///
    /// 4xx means "this request was wrong", which for an upload is normally fatal — a retry
    /// sends the identical bytes to the identical endpoint. The exceptions are the codes that
    /// describe a *momentary* condition rather than the request:
    ///
    /// - **401** — the bearer token expired. The drain already refreshes and retries
    ///   once; if one still reaches here, the next drain starts with a fresh token.
    ///   Treating this as permanent is what quietly destroyed background sync: every photo a
    ///   background drain touched went to `failed` on its *first* attempt, reachable only by
    ///   tapping "Retry Failed" in Settings.
    /// - **408 / 429** — request timeout and rate limiting, both explicitly retryable.
    static func isPermanent(_ error: UploadError) -> Bool {
        if case .serverError(let code) = error {
            if code == 401 || code == 408 || code == 429 { return false }
            return (400..<500).contains(code)
        }
        return false
    }

    /// The dates and provenance a photo's Drive file should carry: when the picture was taken,
    /// when it was last edited, and the asset it came from.
    static func importMetadata(for entry: PhotoSyncQueue.Entry) -> DriveImportMetadata {
        DriveImportMetadata(
            createdAt: entry.creationDate,
            updatedAt: entry.modificationDate ?? entry.creationDate,
            importSource: importSource(forAssetIdentifier: entry.id)
        )
    }
}

// MARK: - PhotoUploadRequest

/// Everything one photo's upload is prepared from.
struct PhotoUploadRequest {
    let export: PhotoExport
    let parentFolderID: String?
    /// The upload's stable identity — see ``PhotoSyncRules/uploadID(forAssetIdentifier:)``.
    let uploadID: String
    /// The photo's capture and edit dates, sent with the body.
    let importMetadata: DriveImportMetadata
    /// `false` when photo sync is Wi-Fi only: the transfer may start long after it was
    /// prepared, on whatever network the phone has by then.
    let allowsExpensiveNetworkAccess: Bool
}

/// An earlier attempt a drain expected to collect was no longer there to collect. Not a
/// failure of the photo — it is simply prepared again, at no cost to its retry budget.
struct EarlierUploadVanished: Error {}

/// The second half of an upload: sends what was prepared and returns the server's answer.
typealias PhotoUploadSubmission = () async throws -> UploadResult
