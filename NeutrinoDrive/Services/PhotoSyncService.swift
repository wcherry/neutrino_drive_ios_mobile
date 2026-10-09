import Foundation
import Photos
import UIKit
import Network
import BackgroundTasks
import UniformTypeIdentifiers
import os.log
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto

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

    var errorDescription: String? {
        switch self {
        case .assetNotFound: return "The photo could not be found in the library."
        case .videoExcluded: return "Video sync is turned off."
        case .exportFailed:  return "The photo could not be read for upload."
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
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: PhotoExportError.exportFailed)
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
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
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

// MARK: - PhotoUploadRequest

/// Everything one photo's upload is prepared from.
struct PhotoUploadRequest {
    let export: PhotoExport
    let parentFolderID: String?
    /// The upload's stable identity — see ``PhotoSyncService/uploadID(forAssetIdentifier:)``.
    let uploadID: String
    /// The photo's capture and edit dates, sent with the body.
    let importMetadata: DriveImportMetadata
    /// `false` when photo sync is Wi-Fi only: the transfer may start long after it was
    /// prepared, on whatever network the phone has by then.
    let allowsExpensiveNetworkAccess: Bool
}

/// The second half of an upload: sends what was prepared and returns the server's answer.
typealias PhotoUploadSubmission = () async throws -> UploadResult

/// An earlier attempt the drain expected to collect was no longer there to collect. Not a
/// failure of the photo — it is simply prepared again, at no cost to its retry budget.
private struct EarlierUploadVanished: Error {}

// MARK: - PhotoSyncStatus

enum PhotoSyncStatus: Equatable {
    case disabled
    case idle
    case uploading(name: String, index: Int, total: Int)
    /// Every queued photo is prepared and handed to iOS; only the transfers are left.
    case transferring(count: Int)
    case waitingForWiFi
    case waitingToCharge
    case pausedMissingKey
    case pausedNotAuthenticated
    case failed(count: Int)
    case permissionLimited
    case permissionDenied

    var displayText: String {
        switch self {
        case .disabled:                          return "Off"
        case .idle:                              return "Up to date"
        case .uploading(let name, let i, let n):  return "Uploading \(name) (\(i) of \(n))"
        case .transferring(let count):           return "Sending \(count) photo\(count == 1 ? "" : "s")"
        case .waitingForWiFi:                    return "Waiting for Wi-Fi"
        case .waitingToCharge:                   return "Waiting to charge"
        case .pausedMissingKey:                  return "Paused — import your encryption key"
        case .pausedNotAuthenticated:            return "Paused — sign in to resume"
        case .failed(let count):                 return "\(count) photo\(count == 1 ? "" : "s") failed"
        case .permissionLimited:                 return "Limited photo access"
        case .permissionDenied:                  return "Photo access denied"
        }
    }
}

// MARK: - PhotoBackfillWindow

/// How far back into the *existing* photo library automatic backup reaches.
///
/// The raw value is the number of days, which is what `PhotoSyncService.backfillDays`
/// persists: `0` means the shipped behaviour (only assets created after the feature was
/// switched on) and `-1` means the whole library, however old.
enum PhotoBackfillWindow: Int, CaseIterable, Identifiable {
    case off     = 0
    case week    = 7
    case month   = 30
    case quarter = 90
    case year    = 365
    case all     = -1

    var id: Int { rawValue }
    var days: Int { rawValue }

    /// The window a stored day count belongs to. An exact match wins; anything else rounds
    /// *up* to the next widest preset, so a value written by an older or newer build is never
    /// narrowed silently into re-uploading less than the user asked for.
    init(days: Int) {
        if days < 0 { self = .all; return }
        if days == 0 { self = .off; return }
        self = Self.allCases
            .filter { $0.rawValue > 0 }
            .sorted { $0.rawValue < $1.rawValue }
            .first { $0.rawValue >= days } ?? .all
    }

    var label: String {
        switch self {
        case .off:     return "Off"
        case .week:    return "Last 7 Days"
        case .month:   return "Last 30 Days"
        case .quarter: return "Last 90 Days"
        case .year:    return "Last Year"
        case .all:     return "All Photos"
        }
    }
}

// MARK: - BackgroundTaskState

/// The two flags one `BGTask` run needs, behind a lock.
///
/// `BGTask.expirationHandler` is called on an arbitrary thread while the drain it is
/// interrupting runs on the main actor, so plain captured `var`s are a data race — and
/// `setTaskCompleted` called twice is not a soft failure but a crash. `claimCompletion`
/// returns `true` to exactly one caller, whichever gets there first.
private final class BackgroundTaskState {
    private let lock = NSLock()
    private var expired = false
    private var completed = false

    var isExpired: Bool {
        lock.lock(); defer { lock.unlock() }
        return expired
    }

    func markExpired() {
        lock.lock(); defer { lock.unlock() }
        expired = true
    }

    /// `true` for the first caller only — the one that owns calling `setTaskCompleted`.
    func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

// MARK: - PhotoSyncService

/// Coordinator for opt-in background photo-library sync: owns enablement state, the
/// PhotoKit change observer, the persistent upload queue, and the drain loop that encrypts
/// and uploads new assets via `UploadService`.
@MainActor
final class PhotoSyncService: NSObject, ObservableObject {

    // MARK: - UserDefaults keys

    enum Keys {
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
    }

    static let defaultFolderName = "iPhone Photos"

    /// `BGProcessingTask` — generous runtime, but iOS treats it as deferrable maintenance and
    /// in practice grants it when the device is charging and idle, often overnight. Right for
    /// clearing a large backlog; far too rare to be the only thing photo sync relies on.
    static let backgroundTaskIdentifier = "com.neutrino.drive.photosync"

    /// `BGAppRefreshTask` — a much shorter budget (~30s), but iOS schedules it from the
    /// user's actual usage pattern and requires neither charging nor idle. This is what makes
    /// photos upload while the app is merely backgrounded rather than only overnight.
    static let refreshTaskIdentifier = "com.neutrino.drive.photosync.refresh"
    static let maxAssetSizeBytes: Int64 = 512 * 1024 * 1024   // 512 MB — see plan "Known risks"

    // MARK: - Published (UI-facing) State

    @Published private(set) var status: PhotoSyncStatus = .disabled
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var failedCount: Int = 0
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined

    /// Progress of the one-time "Repair Photo Dates" pass.
    ///
    /// Settable because ``repairPhotoDates()`` lives in `PhotoDateRepair.swift` and `private(set)`
    /// is file-scoped; nothing else writes it.
    @Published var dateRepairState: PhotoDateRepairState = .idle

    /// Bound directly by `PhotoSyncSettingsView`'s toggle. Setting this to `true` kicks off
    /// the (async) permission request; on denial the value is reverted to `false`.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                Task { await handleEnabled() }
            } else {
                handleDisabled()
            }
        }
    }

    // MARK: - Test seams (network / power / auth — overridable by tests, real defaults otherwise)

    /// Whether the current network path is Wi-Fi. Updated live by the internal
    /// `NWPathMonitor`; tests set this directly instead of faking a real path.
    @Published var isOnWiFi: Bool = true
    /// Whether the current network path is expensive/constrained (cellular, personal
    /// hotspot, etc.) — treated the same as "not Wi-Fi" when `wifiOnly` is set.
    @Published var isNetworkExpensive: Bool = false

    var batteryStateProvider: () -> UIDevice.BatteryState = { UIDevice.current.batteryState }
    var isLowPowerModeEnabledProvider: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var hasAccessTokenProvider: () -> Bool = { KeychainService.load(forKey: AuthService.accessTokenKey) != nil }
    var hasStoredKeysProvider: () -> Bool = { KeyImportService.hasStoredKeys() }

    /// Resolves the destination folder ID for `name` under `parentID`. Wired to
    /// `driveService.ensureFolder` in `configure(driveService:uploadService:)`; tests inject
    /// a spy/closure directly.
    var folderResolver: ((String, String?) async throws -> String)?

    /// Prepares one photo's upload — encrypts it and writes the complete request body to disk —
    /// and returns what sends it. Wired to `uploadService.prepareUpload` / `submit` in
    /// `configure`; tests inject a fake that skips the network entirely.
    ///
    /// Two halves because they have different limits. Preparing holds the whole photo in
    /// memory and needs PhotoKit, so photos are prepared one at a time. Sending needs neither,
    /// and is mostly waiting on iOS's transfer daemon, so many are sent at once — see
    /// ``maxTransfersInFlight``. A drain that awaited each transfer before preparing the next
    /// moved about one photo per wake-up in the background (issue #38).
    var uploadPreparer: ((PhotoUploadRequest) async throws -> PhotoUploadSubmission)?

    /// What collects an earlier attempt at an upload id, or `nil` when there is none.
    ///
    /// After a relaunch, a queued photo's transfer may already be finished, or still running,
    /// in the background session; or its bytes may be committed with only the key left to
    /// send. Collecting that is cheap and preparing again is not — and sending again would
    /// make a second file. Wired to `uploadService` in `configure`; tests leave it `nil`.
    var earlierUploadCollector: ((String) async -> PhotoUploadSubmission?)?

    /// How many prepared uploads may be waiting on the network at once.
    ///
    /// Each holds its body in a temp file until it finishes, so this bounds the disk a backlog
    /// can take; and each carries a bearer token that expires in 15 minutes, so a transfer
    /// that waits behind too many others starts too late to be accepted. Settable for tests.
    var maxTransfersInFlight = 12

    /// Applies a file's real dates and provenance once its content is in place. Wired to
    /// `driveService.setImportMetadata` in `configure`; tests inject a spy.
    ///
    /// Only used against a server that did not store the dates sent with the upload — see
    /// ``stampCaptureDatesIfNeeded(on:from:)``.
    var importMetadataStamper: ((String, DriveImportMetadata) async throws -> Void)?

    /// Reads one page of the photo-sync destination folder. Wired to
    /// `driveService.folderFilesPage`; used only by the repair pass.
    var folderPageLister: ((String, Int, Int) async throws -> [DriveFolderFile])?

    /// Resolves `PHAsset.localIdentifier`s to the filename and dates the repair pass matches
    /// on. Defaults to the real PhotoKit-backed provider; tests inject a fake.
    var assetMetadataProvider: PhotoAssetMetadataProviding = PHKitAssetMetadataProvider()

    /// Exports a `PHAsset.localIdentifier` to bytes. Defaults to the real PhotoKit-backed
    /// exporter; tests inject a fake.
    var assetExporter: PhotoAssetExporting

    /// Renews the access token when it is close to expiry. Wired to
    /// `authService.refreshTokenIfNeeded()` in `configure`; tests inject a spy.
    ///
    /// Photo sync is the one upload path that has to do this for itself. Access tokens last
    /// 15 minutes, and every *other* caller reaches the server through `DriveService`, which
    /// refreshes on the way past. The upload does not: `E2EEUploader` reads the bearer token
    /// straight out of the Keychain so the share extension can use it without an `AuthService`.
    /// In the foreground that is invisible, because the user browsing Drive keeps the token
    /// fresh; a drain that runs with the app off screen has nothing keeping it fresh at all.
    var tokenRefresher: (() async -> Void)?

    // MARK: - Dependencies

    weak var driveService: DriveService?
    weak var uploadService: UploadService?

    /// Wires `folderResolver`/`uploadPreparer`/`tokenRefresher` to real dependencies. Call once
    /// at launch — from `NeutrinoDriveApp.init()`, so a scene-less background launch is wired
    /// too.
    func configure(driveService: DriveService, uploadService: UploadService, authService: AuthService) {
        self.driveService = driveService
        self.uploadService = uploadService
        folderResolver = { [weak driveService] name, parentID in
            guard let driveService else { throw DriveError.notAuthenticated }
            return try await driveService.ensureFolder(named: name, parentID: parentID)
        }
        uploadPreparer = { [weak uploadService] request in
            guard let uploadService else { throw UploadError.notAuthenticated }
            let prepared = try await uploadService.prepareUpload(
                data: request.export.data, fileName: request.export.fileName,
                mimeType: request.export.mimeType, parentFolderID: request.parentFolderID,
                thumbnailBase64: request.export.thumbnailBase64, uploadID: request.uploadID,
                importMetadata: request.importMetadata,
                allowsExpensiveNetworkAccess: request.allowsExpensiveNetworkAccess
            )
            return { [weak uploadService] in
                guard let uploadService else { throw UploadError.notAuthenticated }
                return try await uploadService.submit(prepared)
            }
        }
        earlierUploadCollector = { [weak uploadService] uploadID in
            guard let uploadService, await uploadService.hasEarlierUpload(uploadID: uploadID) else {
                return nil
            }
            return { [weak uploadService] in
                guard let uploadService,
                      let result = try await uploadService.earlierUpload(uploadID: uploadID) else {
                    throw EarlierUploadVanished()
                }
                return result
            }
        }
        importMetadataStamper = { [weak driveService] fileID, metadata in
            guard let driveService else { throw DriveError.notAuthenticated }
            try await driveService.setImportMetadata(fileID: fileID, metadata: metadata)
        }
        folderPageLister = { [weak driveService] folderID, limit, offset in
            guard let driveService else { throw DriveError.notAuthenticated }
            return try await driveService.folderFilesPage(folderID: folderID, limit: limit, offset: offset)
        }
        tokenRefresher = { [weak authService] in
            await authService?.refreshTokenIfNeeded()
        }
        // A photo's transfer can finish in a process that never ran a drain — iOS relaunches the
        // app with no UI just to deliver it. Collected here, the photo is marked done before that
        // process is suspended for good; left alone, the result dies with it and the photo is
        // uploaded a second time. Wired here, in `init()`, because that relaunch runs nothing else.
        BackgroundTransferService.shared.setOrphanHandler { [weak self] transferID in
            Task { @MainActor in await self?.collectFinishedTransfer(transferID: transferID) }
        }
    }

    // MARK: - Private

    private let defaults: UserDefaults
    private let queueStore: PhotoSyncQueueStore
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "PhotoSyncService")
    private var queue: PhotoSyncQueue
    private var isObserving = false
    private var isDraining = false
    /// A drain was asked for while one was running. See ``drain(ignoringPowerConstraint:isBackgroundExpired:)``.
    private var drainRequested = false
    /// Entries with a transfer this process is waiting on. Never prepared a second time while
    /// listed here; the drain and ``collectFinishedTransfer(transferID:)`` both check it.
    private var inFlight: Set<String> = []
    /// A drain parked until something it is waiting on changes. See ``wakeDrain()``.
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Entries that already had their one free retry for a stale folder id or token.
    private var staleStateRetried: Set<String> = []
    /// Not a `let`: a cancelled `NWPathMonitor` cannot be restarted, so disabling and
    /// re-enabling photo sync has to swap in a fresh one.
    private var pathMonitor = NWPathMonitor()
    private var isMonitoringNetwork = false
    private let pathMonitorQueue = DispatchQueue(label: "com.neutrino.drive.photosync.pathmonitor")
    private var backgroundTask: BGProcessingTask?

    /// Keeps the drain loop running for the grace period iOS grants after the app leaves the
    /// foreground. See ``beginDrainAssertion()``.
    private var drainAssertionID: UIBackgroundTaskIdentifier = .invalid
    private var drainAssertionExpired = false

    // MARK: - Init

    init(defaults: UserDefaults = .standard,
        queueStore: PhotoSyncQueueStore = PhotoSyncQueueStore(),
        assetExporter: PhotoAssetExporting = PHKitAssetExporter()) {
        self.defaults = defaults
        self.queueStore = queueStore
        self.assetExporter = assetExporter
        self.queue = queueStore.load()
        self.isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        super.init()
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        refreshCounts()
        if !isEnabled { status = .disabled }
    }

    // MARK: - Settings accessors (used by PhotoSyncSettingsView)

    var folderName: String {
        get { defaults.string(forKey: Keys.folderName) ?? Self.defaultFolderName }
        set {
            defaults.set(newValue, forKey: Keys.folderName)
            defaults.removeObject(forKey: Keys.folderID)   // re-resolve on next upload
        }
    }

    var includeVideos: Bool {
        get { defaults.object(forKey: Keys.includeVideos) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.includeVideos) }
    }

    var wifiOnly: Bool {
        get { defaults.object(forKey: Keys.wifiOnly) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.wifiOnly) }
    }

    var whileChargingOnly: Bool {
        get { defaults.object(forKey: Keys.whileChargingOnly) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.whileChargingOnly) }
    }

    /// How far back into the existing library automatic backup reaches, in days.
    ///
    /// `0` (the default) preserves the original contract: nothing that was in the library
    /// when the feature was switched on is uploaded. A positive value reaches that many days
    /// before the anchor date; `-1` reaches the whole library. Widening the window schedules
    /// a one-off backfill scan — narrowing it only stops *future* scans, since assets already
    /// queued or uploaded are not un-backed-up.
    var backfillDays: Int {
        get { defaults.object(forKey: Keys.backfillDays) as? Int ?? 0 }
        set {
            guard newValue != backfillDays else { return }
            // Backed by `UserDefaults`, not `@Published`, so nothing would otherwise tell
            // SwiftUI to re-read it — the picker would snap back to its old row.
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.backfillDays)
            Task { [weak self] in
                guard let self else { return }
                if await self.runBackfillScanIfNeeded() > 0 {
                    await self.drain(ignoringPowerConstraint: false)
                }
            }
        }
    }

    /// The earliest creation date an asset may carry and still be picked up, given a
    /// `backfillDays` window and the anchor set when the feature was switched on.
    ///
    /// Days are subtracted with `Calendar`, not by multiplying 86 400 — "30 days ago" either
    /// side of a DST transition is not 30 × 24 hours, and a cutoff that drifts by an hour is a
    /// photo that silently misses the window.
    static func backfillCutoff(days: Int, anchorDate: Date, now: Date = Date(),
                               calendar: Calendar = .current) -> Date {
        if days < 0 { return .distantPast }
        guard days > 0 else { return anchorDate }
        let windowStart = calendar.date(byAdding: .day, value: -days, to: now)
            ?? now.addingTimeInterval(-Double(days) * 86_400)
        return min(anchorDate, windowStart)
    }

    /// The cutoff every enqueue path filters on: the anchor date, widened by `backfillDays`.
    ///
    /// `.distantFuture` when there is no anchor at all, which is the state of a service that
    /// has never been switched on — a backfill window must never be able to turn that into
    /// "upload the library".
    private var effectiveAnchorDate: Date {
        guard let anchor = defaults.object(forKey: Keys.anchorDate) as? Date else { return .distantFuture }
        return Self.backfillCutoff(days: backfillDays, anchorDate: anchor)
    }

    /// Assets created before this sort behind newer ones in the drain loop — see
    /// ``PhotoSyncQueue/drainable(asOf:newerThan:)``. It is the *anchor*, not the backfill
    /// cutoff: everything the backfill reached back for is by definition older than it.
    private var backlogBoundary: Date {
        defaults.object(forKey: Keys.anchorDate) as? Date ?? .distantPast
    }

    private func drainableEntries() -> [PhotoSyncQueue.Entry] {
        queue.drainable(newerThan: backlogBoundary)
    }

    var failedEntries: [PhotoSyncQueue.Entry] { queue.failed }

    /// When iOS last gave photo sync background runtime, or `nil` if it never has.
    ///
    /// Surfaced in Settings because it is the one fact that separates the two very different
    /// causes of "my photos only upload when I open the app": never set means iOS is not
    /// running the background tasks (force-quitting the app from the switcher stops them
    /// entirely until the next manual launch), whereas a recent value points at the drain.
    var lastBackgroundRunAt: Date? { defaults.object(forKey: Keys.lastBackgroundRun) as? Date }

    // MARK: - Photo-date repair support
    //
    // The pass itself is in `PhotoDateRepair.swift`. These are the pieces of this class's
    // otherwise-private state it needs, kept to a deliberate minimum.

    /// The cached destination folder, or `nil` if no photo has been uploaded yet.
    var photoFolderID: String? { defaults.string(forKey: Keys.folderID) }

    /// `PHAsset.localIdentifier`s this device has already uploaded — the set the repair pass
    /// builds its device-side filename lookup from.
    var completedAssetIdentifiers: [String] { Array(queue.completed.keys) }

    /// The last completed repair pass, so Settings can report it after a relaunch.
    var lastDateRepair: PhotoDateRepairReport? {
        get {
            guard let data = defaults.data(forKey: Keys.lastDateRepair) else { return nil }
            return try? JSONDecoder.photoSync.decode(PhotoDateRepairReport.self, from: data)
        }
        set {
            // Backed by `UserDefaults`, not `@Published`, so nothing would otherwise tell
            // SwiftUI to re-read it.
            objectWillChange.send()
            guard let newValue, let data = try? JSONEncoder.photoSync.encode(newValue) else {
                defaults.removeObject(forKey: Keys.lastDateRepair)
                return
            }
            defaults.set(data, forKey: Keys.lastDateRepair)
        }
    }

    // MARK: - Lifecycle

    /// Called once at app launch (and safe to call again, e.g. on scenePhase changes). When
    /// disabled or the feature flag is off, this is a no-op — no PhotoKit observer is
    /// registered and no permission is requested, so a disabled feature is invisible in the
    /// permission prompts.
    func start() {
        guard FeatureFlags.photoAutoSync, isEnabled else {
            status = .disabled
            return
        }
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            status = authorizationStatus == .denied || authorizationStatus == .restricted ? .permissionDenied : .disabled
            return
        }
        startObservingIfNeeded()
        startNetworkMonitoring()
        Task {
            await runCatchUpScan()
            await runBackfillScanIfNeeded()
            await drain(ignoringPowerConstraint: false)
        }
    }

    /// Registers both background-task handlers. Must be called before the app finishes
    /// launching — hence `NeutrinoDriveApp.init()`. No-ops when the feature flag is off.
    ///
    /// `register` returns `false` when the identifier is missing from
    /// `BGTaskSchedulerPermittedIdentifiers` or the call came too late, and every later
    /// `submit` for that identifier then throws. Discarding that result is how a completely
    /// dead background path can look perfectly healthy from the outside, so it is logged.
    func registerBackgroundTask() {
        guard FeatureFlags.photoAutoSync else { return }

        let registeredProcessing = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: nil
        ) { [weak self] task in
            self?.handleBackgroundTask(task)
        }
        let registeredRefresh = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil
        ) { [weak self] task in
            self?.handleBackgroundTask(task)
        }

        if !registeredProcessing {
            logger.error("BGTaskScheduler refused \(Self.backgroundTaskIdentifier, privacy: .public)")
        }
        if !registeredRefresh {
            logger.error("BGTaskScheduler refused \(Self.refreshTaskIdentifier, privacy: .public)")
        }
    }

    // MARK: - Enable / Disable

    private func handleEnabled() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        switch status {
        case .authorized, .limited:
            // Initial baseline: nothing already in the library is uploaded — only assets
            // created from this moment on. A reinstall (which loses the queue file) also
            // starts fresh here rather than re-uploading history.
            defaults.set(Date(), forKey: Keys.anchorDate)
            defaults.removeObject(forKey: Keys.changeToken)
            // Fresh anchor, fresh backfill: the window is measured against it, and anything
            // captured while the feature was off is only reachable by sweeping again.
            defaults.removeObject(forKey: Keys.backfillScannedFrom)
            self.status = status == .limited ? .permissionLimited : .idle
            startObservingIfNeeded()
            startNetworkMonitoring()
            await captureInitialChangeToken()
            if await runBackfillScanIfNeeded() > 0 {
                await drain(ignoringPowerConstraint: false)
            }
        case .denied, .restricted:
            isEnabled = false   // revert the toggle; caller deep-links to Settings
            self.status = .permissionDenied
        case .notDetermined:
            isEnabled = false
            self.status = .disabled
        @unknown default:
            isEnabled = false
            self.status = .disabled
        }
    }

    private func handleDisabled() {
        stopObserving()
        stopNetworkMonitoring()
        status = .disabled
    }

    // MARK: - PhotoKit observation

    private func startObservingIfNeeded() {
        guard !isObserving else { return }
        PHPhotoLibrary.shared().register(self)
        isObserving = true
    }

    private func stopObserving() {
        guard isObserving else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        isObserving = false
    }

    // MARK: - Network monitoring

    /// Idempotent: `start()` now runs on every foreground transition, and calling
    /// `NWPathMonitor.start` twice on the same monitor is not a supported operation.
    private func startNetworkMonitoring() {
        guard !isMonitoringNetwork else { return }
        isMonitoringNetwork = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isOnWiFi = path.usesInterfaceType(.wifi)
                self.isNetworkExpensive = path.isExpensive || path.isConstrained
                if path.status == .satisfied {
                    await self.drain(ignoringPowerConstraint: false)
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func stopNetworkMonitoring() {
        guard isMonitoringNetwork else { return }
        pathMonitor.cancel()
        isMonitoringNetwork = false
        // A cancelled monitor is dead for good — without a replacement, re-enabling photo
        // sync would leave `isOnWiFi` frozen at whatever it last read.
        pathMonitor = NWPathMonitor()
    }

    // MARK: - Change enqueue (pure — testable without PhotoKit)

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

    /// Enqueues every asset in `assets` that passes `newIdentifiers`, persists the queue, and
    /// returns the number newly enqueued.
    @discardableResult
    func enqueueIfNeeded(_ assets: [PhotoAssetProviding]) -> Int {
        let newOnes = Self.newIdentifiers(from: assets, anchorDate: effectiveAnchorDate,
                                          includeVideos: includeVideos, queue: queue)
        for entry in newOnes {
            queue.enqueue(id: entry.id, creationDate: entry.creationDate,
                          modificationDate: entry.modificationDate)
        }
        if !newOnes.isEmpty {
            persistQueue()
            scheduleBackgroundTask()
        }
        return newOnes.count
    }

    // MARK: - Catch-up scan

    private func runCatchUpScan() async {
        guard FeatureFlags.photoAutoSync, isEnabled else { return }
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }

        if #available(iOS 16.0, *), let tokenData = defaults.data(forKey: Keys.changeToken) {
            do {
                if let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: tokenData) {
                    try await runPersistentChangeCatchUp(since: token)
                    return
                }
            } catch let error as PHPhotosError where error.code == .persistentChangeTokenExpired {
                logger.info("catch-up: change token expired, falling back to bounded fetch")
            } catch {
                logger.error("catch-up: fetchPersistentChanges failed: \(error, privacy: .public) — falling back")
            }
        }
        runBoundedFallbackScan()
    }

    @available(iOS 16.0, *)
    private func runPersistentChangeCatchUp(since token: PHPersistentChangeToken) async throws {
        let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
        var assets: [PhotoAssetProviding] = []
        for change in changes {
            guard let details = try? change.changeDetails(for: PHObjectType.asset) else { continue }
            for identifier in details.insertedLocalIdentifiers {
                let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                if let asset = result.firstObject { assets.append(asset) }
            }
        }
        // Persist enqueues before advancing the token, so a crash mid-enqueue replays
        // this catch-up window rather than silently dropping it.
        enqueueIfNeeded(assets)
        let newToken = PHPhotoLibrary.shared().currentChangeToken
        let archived = try? NSKeyedArchiver.archivedData(withRootObject: newToken, requiringSecureCoding: true)
        defaults.set(archived, forKey: Keys.changeToken)
    }

    private func runBoundedFallbackScan() {
        let anchor = defaults.object(forKey: Keys.anchorDate) as? Date ?? .distantFuture
        let lastSync = defaults.object(forKey: Keys.lastSuccessfulSync) as? Date ?? .distantPast
        // Deliberately the *anchor*, not `effectiveAnchorDate`: this scan exists to cover the
        // gap since the last successful sync, and it runs on every launch. Reaching back over
        // the whole backfill window here would re-enumerate it every time — that sweep is
        // `runBackfillScanIfNeeded()`'s job, and it runs once.
        let cutoff = max(anchor, lastSync)

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", cutoff as NSDate)
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PhotoAssetProviding] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        enqueueIfNeeded(assets)
    }

    // MARK: - Backfill scan

    /// Sweeps the part of the existing library that `backfillDays` reaches back for, once per
    /// widening of the window, and returns how many assets it newly enqueued.
    ///
    /// Bounded by `Keys.backfillScannedFrom`: a window that has already been swept is skipped,
    /// so this is a cheap no-op on every launch after the first. The recorded date is only
    /// ever moved *earlier*, and a rolling window ("last 30 days") moves its cutoff forward as
    /// time passes, so re-running it costs one comparison. The anchor reset in
    /// `handleEnabled()` clears it, which is what lets a disable/re-enable cycle pick up
    /// whatever was captured in between.
    @discardableResult
    private func runBackfillScanIfNeeded() async -> Int {
        guard FeatureFlags.photoAutoSync, isEnabled else { return 0 }
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return 0 }

        let cutoff = effectiveAnchorDate
        guard cutoff != .distantFuture else { return 0 }
        if let scannedFrom = defaults.object(forKey: Keys.backfillScannedFrom) as? Date,
           scannedFrom <= cutoff {
            return 0
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", cutoff as NSDate)
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PhotoAssetProviding] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        let enqueued = enqueueIfNeeded(assets)
        defaults.set(cutoff, forKey: Keys.backfillScannedFrom)
        logger.info("backfill scan enqueued \(enqueued) asset(s) from \(assets.count) candidate(s)")
        return enqueued
    }

    private func captureInitialChangeToken() async {
        guard #available(iOS 16.0, *) else { return }
        let token = PHPhotoLibrary.shared().currentChangeToken
        let archived = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        defaults.set(archived, forKey: Keys.changeToken)
    }

    // MARK: - Drain loop

    /// Evaluates constraints and, if satisfied, uploads pending entries one at a time until
    /// the queue is empty, a constraint is no longer satisfied, or (in the background) the
    /// task expires.
    ///
    /// - Parameter ignoringPowerConstraint: `true` for the foreground "Sync Now" action,
    ///   which ignores `whileChargingOnly` but still honours `wifiOnly` (unless the caller
    ///   has separately confirmed cellular use).
    /// - Parameter isBackgroundExpired: polled between items so the `BGProcessingTask`
    ///   expiration handler can stop the loop promptly.
    ///
    /// A drain asked for while one is running is not dropped: the running one is woken to take
    /// in whatever changed, and another runs after it. The running drain may be parked on a
    /// transfer, with an expiry flag from a background window that has long since closed — a
    /// drain refused outright would leave a photo taken now waiting for that transfer.
    @discardableResult
    func drain(ignoringPowerConstraint: Bool, isBackgroundExpired: (() -> Bool)? = nil) async -> Bool {
        guard !isDraining else {
            drainRequested = true
            wakeDrain()
            return false
        }

        // Claimed before the first `await` below, not after the constraint checks: the
        // refresh suspends, and without the flag already set a second drain (the network
        // path monitor fires one on every change) would walk straight through this guard.
        isDraining = true
        defer {
            isDraining = false
            if drainRequested {
                drainRequested = false
                Task { await self.drain(ignoringPowerConstraint: false) }
            }
        }

        // Renew the token *before* deciding anything. A background drain is typically the
        // first thing to touch the network in hours, so its token is almost always stale —
        // and an upload with a stale token returns 401, which `isPermanent` reads as fatal.
        // Only when there is something to upload: `drain` is called on every network change.
        if !drainableEntries().isEmpty {
            await tokenRefresher?()
        }

        guard hasAccessTokenProvider() else {
            status = .pausedNotAuthenticated
            rescheduleIfWorkRemains()
            return false
        }
        guard hasStoredKeysProvider() else {
            status = .pausedMissingKey
            rescheduleIfWorkRemains()
            return false
        }
        if wifiOnly && (!isOnWiFi || isNetworkExpensive) {
            status = .waitingForWiFi
            rescheduleIfWorkRemains()
            return false
        }
        if !ignoringPowerConstraint && whileChargingOnly && batteryStateProvider() == .unplugged {
            status = .waitingToCharge
            rescheduleIfWorkRemains()
            return false
        }
        if isBackgroundExpired != nil && isLowPowerModeEnabledProvider() {
            // Low Power Mode pauses background drains only; foreground "Sync Now" still works.
            return false
        }

        beginDrainAssertion()
        defer { endDrainAssertion() }

        // Prepare one photo at a time, but don't wait for its transfer before preparing the next:
        // up to `maxTransfersInFlight` go to iOS together, and are carried by its transfer daemon
        // while this process is suspended. Waiting for each one is what limited a background
        // drain to about one photo per wake-up (issue #38).
        var uploadedAny = false
        let total = drainableEntries().count
        var index = 0
        while true {
            if drainAssertionExpired { break }
            if let isBackgroundExpired, isBackgroundExpired() { break }
            if inFlight.count < maxTransfersInFlight,
               let entry = drainableEntries().first(where: { !inFlight.contains($0.id) }) {
                index += 1
                // `max`: a retry is counted again, and must not read "4 of 3".
                status = .uploading(name: entry.id, index: index, total: max(total, index))
                await startUpload(entry)
                uploadedAny = true
                continue
            }
            // Nothing more to prepare, or no room for it. Wait for a transfer to finish — it
            // may free a slot, or come back asking to be prepared again.
            guard !inFlight.isEmpty else { break }
            // Except in a `BGTask` with nothing left to prepare: the transfers are iOS's now,
            // and their results are collected whenever they land. Holding the task open to
            // watch them would only run it into its expiry, which iOS counts against us.
            if isBackgroundExpired != nil,
               !drainableEntries().contains(where: { !inFlight.contains($0.id) }) { break }
            status = .transferring(count: inFlight.count)
            await waitForDrainEvent()
        }

        refreshCounts()
        if pendingCount == 0 {
            status = failedCount > 0 ? .failed(count: failedCount) : .idle
        } else {
            if !inFlight.isEmpty { status = .transferring(count: inFlight.count) }
            // Stopped with work still queued — expiry, or an entry in backoff. Without a
            // pending request the queue would only move again the next time the user
            // happens to open the app.
            scheduleBackgroundTask()
        }
        return uploadedAny
    }

    /// Parks the drain until ``wakeDrain()``.
    private func waitForDrainEvent() async {
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    /// Lets a parked drain look again: a transfer finished, time ran out, or another drain was
    /// asked for. Everything here is main-actor state, so there is no window between the drain
    /// deciding to wait and its continuation being registered.
    private func wakeDrain() {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: - Background execution assertion

    /// Buys the drain loop the grace period iOS grants after the app leaves the foreground.
    ///
    /// This is what makes the common case work at all: `photoLibraryDidChange` fires the
    /// instant a photo is taken, so a drain almost always begins while the app is still
    /// frontmost and is then still running when the user locks the screen. Without an
    /// assertion the process is suspended mid-export and the photo simply waits — the
    /// symptom being "Drive doesn't upload unless I'm looking at it".
    ///
    /// Distinct from `BGProcessingTask`, which schedules a *later* run and does nothing for
    /// a run already under way, and from ``BackgroundTransferService``, which carries the
    /// blob POST but not the PhotoKit export and encryption that prepare it.
    private func beginDrainAssertion() {
        guard drainAssertionID == .invalid else { return }
        drainAssertionExpired = false
        drainAssertionID = UIApplication.shared.beginBackgroundTask(
            withName: "com.neutrino.drive.photosync.drain"
        ) { [weak self] in
            // Suspension is imminent: raise the flag so the loop stops after the item in
            // flight, and hand the assertion back — iOS terminates the app outright for an
            // assertion it has to reclaim itself.
            //
            // Done synchronously, not via `Task { @MainActor in }`. UIKit delivers this on
            // the main thread already, and a hop would queue behind whatever the drain is
            // doing — including `E2EEUploader`'s encryption, which is synchronous main-actor
            // work that runs for seconds on a large photo. There is nothing to persist here:
            // the queue is written to disk after every individual upload.
            self?.drainAssertionExpired = true
            self?.endDrainAssertion()
            // A drain parked on a transfer would otherwise sleep through its own expiry.
            self?.wakeDrain()
        }
    }

    private func endDrainAssertion() {
        guard drainAssertionID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(drainAssertionID)
        drainAssertionID = .invalid
    }

    /// Submits a `BGProcessingTask` request when the queue still holds pending work.
    private func rescheduleIfWorkRemains() {
        guard !queue.pending.isEmpty else { return }
        scheduleBackgroundTask()
    }

    /// Foreground "Sync Now" — bypasses the power constraint (not Wi-Fi, unless the caller
    /// already resolved that with the user).
    func syncNow() {
        Task { await drain(ignoringPowerConstraint: true) }
    }

    /// Moves all `failed` entries back to `pending` and re-runs the drain loop.
    func retryFailed() {
        queue.retryAllFailed()
        persistQueue()
        refreshCounts()
        Task { await drain(ignoringPowerConstraint: true) }
    }

    // MARK: - Per-entry upload

    /// Prepares `entry` and hands its transfer off, returning once it is on its way — not once
    /// it has arrived. The outcome is recorded by ``finishUpload(_:outcome:)`` whenever it lands.
    private func startUpload(_ entry: PhotoSyncQueue.Entry) async {
        inFlight.insert(entry.id)
        let submission: PhotoUploadSubmission
        do {
            submission = try await prepareUpload(entry)
        } catch {
            inFlight.remove(entry.id)
            recordFailure(of: entry, error)
            return
        }
        Task {
            let outcome: Result<UploadResult, Error>
            do {
                outcome = .success(try await submission())
            } catch {
                outcome = .failure(error)
            }
            await finishUpload(entry, outcome: outcome)
        }
    }

    /// Everything before the network: collect an earlier attempt if there is one, otherwise
    /// export, check, and prepare.
    private func prepareUpload(_ entry: PhotoSyncQueue.Entry) async throws -> PhotoUploadSubmission {
        let uploadID = Self.uploadID(forAssetIdentifier: entry.id)
        if let earlier = await earlierUploadCollector?(uploadID) {
            logger.debug("collecting an earlier upload of \(entry.id, privacy: .public)")
            return earlier
        }

        let wifiOnlyBlocksCellular = wifiOnly && (!isOnWiFi || isNetworkExpensive)
        let export = try await assetExporter.exportData(
            for: entry.id,
            includeVideos: includeVideos,
            networkAccessAllowed: !wifiOnlyBlocksCellular
        )
        if export.data.count > Int(Self.maxAssetSizeBytes) {
            throw OversizedAsset()
        }

        let folderID = try await resolveDestinationFolder()
        guard let uploadPreparer else { throw UploadError.notAuthenticated }
        return try await uploadPreparer(PhotoUploadRequest(
            export: export,
            parentFolderID: folderID,
            uploadID: uploadID,
            importMetadata: Self.importMetadata(for: entry),
            allowsExpensiveNetworkAccess: !wifiOnly
        ))
    }

    private struct OversizedAsset: Error {}

    /// Records how a transfer ended and lets the drain look again.
    ///
    /// Two failures are really "the state I cached went stale", and each gets one free retry —
    /// the entry stays pending at no cost to its budget, and the drain prepares it again:
    ///
    /// - **404** — the cached folder ID was deleted or trashed server-side. Cleared, so the
    ///   retry resolves it afresh.
    /// - **401** — the access token expired. A drain can outlive the 15-minute token lifetime
    ///   on a slow link or a long backlog — and a prepared transfer can wait behind others —
    ///   and nothing on the upload path renews it.
    private func finishUpload(_ entry: PhotoSyncQueue.Entry, outcome: Result<UploadResult, Error>) async {
        inFlight.remove(entry.id)
        defer { wakeDrain() }

        switch outcome {
        case .success(let result):
            staleStateRetried.remove(entry.id)
            await recordSuccess(of: entry, result)
        case .failure(UploadError.serverError(let code)) where code == 404
                && !staleStateRetried.contains(entry.id):
            staleStateRetried.insert(entry.id)
            defaults.removeObject(forKey: Keys.folderID)
        case .failure(UploadError.serverError(let code)) where code == 401
                && !staleStateRetried.contains(entry.id):
            staleStateRetried.insert(entry.id)
            await tokenRefresher?()
        case .failure(is EarlierUploadVanished):
            break   // still pending and untouched; it is simply prepared again
        case .failure(let error):
            staleStateRetried.remove(entry.id)
            recordFailure(of: entry, error)
        }
    }

    private func recordSuccess(of entry: PhotoSyncQueue.Entry, _ result: UploadResult) async {
        queue.markCompleted(id: entry.id, fileID: result.id)
        lastSyncedAt = Date()
        defaults.set(lastSyncedAt, forKey: Keys.lastSuccessfulSync)
        persistQueue()

        // After the ledger, and after the content. The photo is safe at this point, which is
        // what lets the stamp fail without consequence.
        await stampCaptureDatesIfNeeded(on: result, from: entry)
    }

    private func recordFailure(of entry: PhotoSyncQueue.Entry, _ error: Error) {
        switch error {
        case is OversizedAsset:
            queue.markFailed(id: entry.id, error: "Too large for automatic backup", permanent: true)
        case let error as UploadError:
            queue.markFailed(id: entry.id, error: error.localizedDescription, permanent: isPermanent(error))
        default:
            queue.markFailed(id: entry.id, error: error.localizedDescription)
        }
        persistQueue()
    }

    // MARK: - Transfers that finish with nobody waiting

    /// Records the outcome of a photo's transfer that finished with no drain waiting for it —
    /// typically in a process iOS launched only to deliver it — and then tops the pipeline up.
    ///
    /// The result is in memory only, so this is the one chance to record it: a photo whose
    /// result dies with the process is prepared and uploaded again. That is also why the
    /// relaunch is worth a drain: it is runtime, and the queue may hold more.
    func collectFinishedTransfer(transferID: String) async {
        guard let assetID = Self.assetIdentifier(forTransferID: transferID),
              !inFlight.contains(assetID),
              let entry = queue.pending.first(where: { $0.id == assetID }),
              let collect = await earlierUploadCollector?(Self.uploadID(forAssetIdentifier: assetID)),
              // Again, after the suspension: a drain may have taken the entry meanwhile.
              !inFlight.contains(assetID),
              queue.pending.contains(where: { $0.id == assetID }) else { return }

        inFlight.insert(assetID)
        let outcome: Result<UploadResult, Error>
        do {
            outcome = .success(try await collect())
        } catch {
            outcome = .failure(error)
        }
        await finishUpload(entry, outcome: outcome)
        if FeatureFlags.photoAutoSync, isEnabled {
            await drain(ignoringPowerConstraint: false)
        }
    }

    /// The asset a photo-sync blob transfer id belongs to, or `nil` for any other transfer.
    nonisolated static func assetIdentifier(forTransferID transferID: String) -> String? {
        let prefix = E2EEUploader.blobTransferID(uploadID: uploadID(forAssetIdentifier: ""))
        guard transferID.hasPrefix(prefix) else { return nil }
        return String(transferID.dropFirst(prefix.count))
    }

    // MARK: - Capture dates

    /// The dates and provenance a photo's Drive file should carry: when the picture was taken,
    /// when it was last edited, and the asset it came from.
    static func importMetadata(for entry: PhotoSyncQueue.Entry) -> DriveImportMetadata {
        DriveImportMetadata(
            createdAt: entry.creationDate,
            updatedAt: entry.modificationDate ?? entry.creationDate,
            importSource: importSource(forAssetIdentifier: entry.id)
        )
    }

    /// Gives the uploaded file the date the picture was taken, when the upload did not already.
    ///
    /// The upload carries the dates itself, and a current server commits them with the file
    /// — echoing the provenance back is how it says so. A server that predates those fields
    /// ignores them, and the file has today's date until this `PATCH` corrects it.
    ///
    /// **Never fatal.** By the time this runs the bytes are committed and the entry is
    /// completed. Failing it would send a good photo back to `pending` and re-upload it on the
    /// next drain — a duplicate file, to fix a wrong date. A warning and the repair pass are
    /// the right answer; see ``repairPhotoDates()``.
    private func stampCaptureDatesIfNeeded(on result: UploadResult, from entry: PhotoSyncQueue.Entry) async {
        let metadata = Self.importMetadata(for: entry)
        guard result.importSource != metadata.importSource,
              let importMetadataStamper else { return }
        do {
            try await importMetadataStamper(result.id, metadata)
        } catch {
            logger.warning("""
                import-metadata patch failed for \(result.id, privacy: .public): \
                \(error.localizedDescription, privacy: .public) — the photo is uploaded but \
                keeps today's date until Repair Photo Dates is run
                """)
        }
    }

    /// The provenance string a photo-sync upload records on its Drive file.
    ///
    /// `import_source` means "came from an archive import" elsewhere, and is reused here with
    /// a prefix rather than given a field of its own on the backend — the cheapest correct
    /// path, and one that keeps this whole change client-side. It carries the asset identifier
    /// so a file can always be traced back to the picture it came from.
    /// `nonisolated` so `PhotoDateRepairPlanner` — pure, static and off the main actor — can
    /// build the same string the upload path stamps.
    nonisolated static func importSource(forAssetIdentifier identifier: String) -> String {
        "photo-sync:\(identifier)"
    }

    /// The stable upload identity for one asset.
    ///
    /// Photo sync is the path that suspends most — a background drain is suspended by
    /// definition — and it is also the only upload path whose retries are automatic, so it is
    /// the one that most needs a retry to recognise its own interrupted attempt. The asset's
    /// `localIdentifier` is the natural key: one asset is one logical upload, however many
    /// attempts it takes. Shares its shape with the `import_source` stamp on purpose.
    nonisolated static func uploadID(forAssetIdentifier identifier: String) -> String {
        importSource(forAssetIdentifier: identifier)
    }

    /// Whether `error` will still fail however many times it is retried.
    ///
    /// 4xx means "this request was wrong", which for an upload is normally fatal — a retry
    /// sends the identical bytes to the identical endpoint. The exceptions are the codes that
    /// describe a *momentary* condition rather than the request:
    ///
    /// - **401** — the bearer token expired. `finishUpload` already refreshes and retries
    ///   once; if one still reaches here, the next drain starts with a fresh token.
    ///   Treating this as permanent is what quietly destroyed background sync: every photo a
    ///   background drain touched went to `failed` on its *first* attempt, reachable only by
    ///   tapping "Retry Failed" in Settings.
    /// - **408 / 429** — request timeout and rate limiting, both explicitly retryable.
    private func isPermanent(_ error: UploadError) -> Bool {
        if case .serverError(let code) = error {
            if code == 401 || code == 408 || code == 429 { return false }
            return (400..<500).contains(code)
        }
        return false
    }

    // MARK: - Folder resolution

    /// Resolves the destination folder ID: cached value if present, otherwise find-or-create
    /// via `folderResolver`, caching the result for next time.
    func resolveDestinationFolder() async throws -> String {
        if let cached = photoFolderID {
            return cached
        }
        guard let folderResolver else { throw DriveError.notAuthenticated }
        let id = try await folderResolver(folderName, nil)
        defaults.set(id, forKey: Keys.folderID)
        return id
    }

    // MARK: - Persistence / counts

    private func persistQueue() {
        queueStore.save(queue)
        refreshCounts()
    }

    private func refreshCounts() {
        pendingCount = queue.pending.count
        failedCount = queue.failed.count
    }

    // MARK: - Background task

    /// Drives one background run, for either task type — the work is identical, only the
    /// budget differs, and the loop already stops on `isBackgroundExpired`.
    private func handleBackgroundTask(_ task: BGTask) {
        scheduleBackgroundTask()   // the system grants exactly one run per submission

        // `expirationHandler` fires on an arbitrary thread while the drain runs on the main
        // actor, so both flags are shared mutable state. `setTaskCompleted` is also a hard
        // crash if called twice ("task has already been completed"), and the old
        // `if !expired` check lost that race whenever the drain finished as expiry landed.
        let state = BackgroundTaskState()
        task.expirationHandler = {
            state.markExpired()
            // Synchronously, not via a main-actor hop: the runtime is already gone.
            if state.claimCompletion() { task.setTaskCompleted(success: false) }
        }

        Task { @MainActor in
            defaults.set(Date(), forKey: Keys.lastBackgroundRun)
            await runCatchUpScan()
            await runBackfillScanIfNeeded()
            await drain(ignoringPowerConstraint: false, isBackgroundExpired: { state.isExpired })
            persistQueueNow()
            if state.claimCompletion() { task.setTaskCompleted(success: !state.isExpired) }
        }
    }

    private func persistQueueNow() {
        queueStore.save(queue)
    }

    /// Submits **both** background requests.
    ///
    /// Two, not one, because they get scheduled on completely different terms: the refresh
    /// task is what iOS actually runs while the phone is in a pocket, and the processing task
    /// is what eventually clears a large backlog once the phone is charging. Submitting a
    /// request replaces any pending one with the same identifier, so calling this often is
    /// harmless.
    func scheduleBackgroundTask(earliestBeginDate: Date = Date().addingTimeInterval(60)) {
        guard FeatureFlags.photoAutoSync, isEnabled else { return }

        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        refresh.earliestBeginDate = earliestBeginDate
        submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = whileChargingOnly
        processing.earliestBeginDate = earliestBeginDate
        submit(processing)
    }

    private func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("scheduled \(request.identifier, privacy: .public)")
        } catch {
            // `.unavailable` is expected on the Simulator, which has no scheduler at all.
            logger.error("submit \(request.identifier, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Test Seams

    #if DEBUG
    func debugIsCompleted(_ id: String) -> Bool { queue.completed[id] != nil }
    func debugCompletedFileID(_ id: String) -> String? { queue.completedFileID(for: id) }
    func debugFailedEntry(_ id: String) -> PhotoSyncQueue.Entry? { queue.failed.first(where: { $0.id == id }) }
    func debugPendingEntry(_ id: String) -> PhotoSyncQueue.Entry? { queue.pending.first(where: { $0.id == id }) }
    /// Seeds the completed ledger, for tests of things that read it — the repair pass builds
    /// its device-side lookup from exactly these identifiers.
    func debugMarkCompleted(_ id: String, fileID: String?) { queue.markCompleted(id: id, fileID: fileID) }
    /// Waits until no transfer is in flight — for tests whose drain stopped before its
    /// transfers finished, as an expired one does.
    func debugSettle() async {
        while !inFlight.isEmpty { await waitForDrainEvent() }
    }
    #endif
}

// MARK: - PHPhotoLibraryChangeObserver

extension PhotoSyncService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            // Live observation: fetch assets created since the anchor date and enqueue any
            // not already known. The persistent-change catch-up (run on launch/foreground)
            // covers the gap while the app was not running; this covers changes while it is.
            // Bounded by the anchor, not the backfill cutoff: this fires on every library
            // change (every frame of a burst), and re-enumerating a year — or with "All
            // Photos", the entire library — each time would be ruinous. Older assets are the
            // one-off `runBackfillScanIfNeeded()` sweep's job.
            let cutoff = self.defaults.object(forKey: Keys.anchorDate) as? Date ?? .distantFuture
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@", cutoff as NSDate)
            let result = PHAsset.fetchAssets(with: options)
            var assets: [PhotoAssetProviding] = []
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
            self.enqueueIfNeeded(assets)
            await self.drain(ignoringPowerConstraint: false)
        }
    }
}

