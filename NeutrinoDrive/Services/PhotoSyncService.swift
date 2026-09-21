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

// MARK: - PhotoSyncStatus

enum PhotoSyncStatus: Equatable {
    case disabled
    case idle
    case uploading(name: String, index: Int, total: Int)
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

    /// Encrypts-and-uploads an export. Wired to `uploadService.upload(data:...)` in
    /// `configure`; tests inject a fake that skips the network entirely.
    ///
    /// Takes the whole `PhotoExport` rather than its fields spread out: it grew a cover
    /// thumbnail the uploader cannot re-derive cheaply, and threading each new piece of an
    /// export through as another positional argument is how a seam ends up with six of them.
    var uploadHandler: ((PhotoExport, String?) async throws -> UploadResult)?

    /// Applies a file's real dates and provenance once its content is in place. Wired to
    /// `driveService.setImportMetadata` in `configure`; tests inject a spy.
    ///
    /// A seam of its own rather than a step inside `uploadHandler`, because it is a different
    /// call to a different endpoint whose failure must not cost the entry — see
    /// ``stampCaptureDates(on:from:)``.
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

    /// Wires `folderResolver`/`uploadHandler`/`tokenRefresher` to real dependencies. Call once
    /// at launch — from `NeutrinoDriveApp.init()`, so a scene-less background launch is wired
    /// too.
    func configure(driveService: DriveService, uploadService: UploadService, authService: AuthService) {
        self.driveService = driveService
        self.uploadService = uploadService
        folderResolver = { [weak driveService] name, parentID in
            guard let driveService else { throw DriveError.notAuthenticated }
            return try await driveService.ensureFolder(named: name, parentID: parentID)
        }
        uploadHandler = { [weak uploadService] export, parentFolderID in
            guard let uploadService else { throw UploadError.notAuthenticated }
            return try await uploadService.upload(data: export.data, fileName: export.fileName,
                                                  mimeType: export.mimeType,
                                                  parentFolderID: parentFolderID,
                                                  reportsProgress: false,
                                                  thumbnailBase64: export.thumbnailBase64)
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
    }

    // MARK: - Private

    private let defaults: UserDefaults
    private let queueStore: PhotoSyncQueueStore
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "PhotoSyncService")
    private var queue: PhotoSyncQueue
    private var isObserving = false
    private var isDraining = false
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
    @discardableResult
    func drain(ignoringPowerConstraint: Bool, isBackgroundExpired: (() -> Bool)? = nil) async -> Bool {
        guard !isDraining else { return false }

        // Claimed before the first `await` below, not after the constraint checks: the
        // refresh suspends, and without the flag already set a second drain (the network
        // path monitor fires one on every change) would walk straight through this guard.
        isDraining = true
        defer { isDraining = false }

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

        var uploadedAny = false
        let total = drainableEntries().count
        var index = 0
        while let entry = drainableEntries().first {
            if drainAssertionExpired { break }
            if let isBackgroundExpired, isBackgroundExpired() { break }
            index += 1
            status = .uploading(name: entry.id, index: index, total: total)
            await performUpload(entry)
            uploadedAny = true
        }

        refreshCounts()
        if pendingCount == 0 {
            status = failedCount > 0 ? .failed(count: failedCount) : .idle
        } else {
            // Stopped with work still queued — expiry, or an entry in backoff. Without a
            // pending request the queue would only move again the next time the user
            // happens to open the app.
            scheduleBackgroundTask()
        }
        return uploadedAny
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
    /// blob POST but not the PhotoKit export or the sealed-key `PUT` around it.
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

    private func performUpload(_ entry: PhotoSyncQueue.Entry) async {
        do {
            let export = try await assetExporter.exportData(
                for: entry.id,
                includeVideos: includeVideos,
                networkAccessAllowed: !(wifiOnly && (!isOnWiFi || isNetworkExpensive))
            )

            if export.data.count > Int(Self.maxAssetSizeBytes) {
                queue.markFailed(id: entry.id, error: "Too large for automatic backup", permanent: true)
                persistQueue()
                return
            }

            try await uploadWithFolderRetry(export: export, entry: entry)
        } catch let error as UploadError {
            queue.markFailed(id: entry.id, error: error.localizedDescription, permanent: isPermanent(error))
            persistQueue()
        } catch {
            queue.markFailed(id: entry.id, error: error.localizedDescription)
            persistQueue()
        }
    }

    /// Uploads `export`, resolving the destination folder first, recovering once from either
    /// of the two failures that are really "the state I cached went stale":
    ///
    /// - **404** — the cached folder ID was deleted or trashed server-side. Clear it, resolve
    ///   again, upload again.
    /// - **401** — the access token expired mid-drain. A drain can outlive the 15-minute token
    ///   lifetime on a slow link or a long backlog, and `resolveDestinationFolder` does not
    ///   renew it once the folder ID is cached, because it never reaches `DriveService`.
    ///
    /// Each is retried exactly once; a second failure is the caller's to record.
    private func uploadWithFolderRetry(export: PhotoExport, entry: PhotoSyncQueue.Entry) async throws {
        let folderID = try await resolveDestinationFolder()
        let result: UploadResult
        do {
            result = try await upload(export: export, parentFolderID: folderID)
        } catch UploadError.serverError(let code) where code == 404 {
            defaults.removeObject(forKey: Keys.folderID)
            let retriedFolderID = try await resolveDestinationFolder()
            result = try await upload(export: export, parentFolderID: retriedFolderID)
        } catch UploadError.serverError(let code) where code == 401 {
            await tokenRefresher?()
            result = try await upload(export: export, parentFolderID: folderID)
        }
        queue.markCompleted(id: entry.id, fileID: result.id)
        lastSyncedAt = Date()
        defaults.set(lastSyncedAt, forKey: Keys.lastSuccessfulSync)
        persistQueue()

        // After the ledger, and after the content. The photo is safe at this point, which is
        // what lets the stamp fail without consequence.
        await stampCaptureDates(on: result.id, from: entry)
    }

    /// Gives the uploaded file the date the picture was taken.
    ///
    /// **A second call, deliberately.** Writing the file's body is what stamps `updated_at`
    /// with the server's clock, so a date sent alongside the content would be overwritten a
    /// moment later — the reason `PATCH /drive/files/{id}/import-metadata` exists at all
    /// (`wcherry/neutrino` #110) and the reason the Takeout runners are shaped this way.
    ///
    /// **Never fatal.** By the time this runs the bytes are committed and the entry is
    /// completed. Failing it would send a good photo back to `pending` and re-upload it on the
    /// next drain — a duplicate file, to fix a wrong date. A warning and the repair pass are
    /// the right answer; see ``repairPhotoDates()``.
    private func stampCaptureDates(on fileID: String, from entry: PhotoSyncQueue.Entry) async {
        guard let importMetadataStamper else { return }
        let metadata = DriveImportMetadata(
            createdAt: entry.creationDate,
            updatedAt: entry.modificationDate ?? entry.creationDate,
            importSource: Self.importSource(forAssetIdentifier: entry.id)
        )
        do {
            try await importMetadataStamper(fileID, metadata)
        } catch {
            logger.warning("""
                import-metadata patch failed for \(fileID, privacy: .public): \
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

    private func upload(export: PhotoExport, parentFolderID: String?) async throws -> UploadResult {
        guard let uploadHandler else { throw UploadError.notAuthenticated }
        return try await uploadHandler(export, parentFolderID)
    }

    /// Whether `error` will still fail however many times it is retried.
    ///
    /// 4xx means "this request was wrong", which for an upload is normally fatal — a retry
    /// sends the identical bytes to the identical endpoint. The exceptions are the codes that
    /// describe a *momentary* condition rather than the request:
    ///
    /// - **401** — the bearer token expired. `uploadWithFolderRetry` already refreshes and
    ///   retries once; if one still reaches here, the next drain starts with a fresh token.
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

