import Foundation
import Photos
import UIKit
import Network
import BackgroundTasks
import UniformTypeIdentifiers
import os.log

// MARK: - PhotoAssetProviding

/// Abstraction over `PHAsset` so unit tests can supply fakes — `PHAsset` cannot be
/// constructed directly in a test target.
protocol PhotoAssetProviding {
    var localIdentifier: String { get }
    var creationDate: Date? { get }
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
        let data = try Data(contentsOf: tempURL)
        return PhotoExport(data: data, fileName: fileName, mimeType: mimeType)
    }

    // MARK: - Naming

    private static func fallbackFileName(for asset: PHAsset, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: asset.creationDate ?? Date())
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
        static let changeToken        = "photoSync.changeToken"
        static let lastSuccessfulSync = "photoSync.lastSuccessfulSyncDate"
    }

    static let defaultFolderName = "iPhone Photos"
    static let backgroundTaskIdentifier = "com.neutrino.drive.photosync"
    static let maxAssetSizeBytes: Int64 = 512 * 1024 * 1024   // 512 MB — see plan "Known risks"

    // MARK: - Published (UI-facing) State

    @Published private(set) var status: PhotoSyncStatus = .disabled
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var failedCount: Int = 0
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined

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

    /// Encrypts-and-uploads `Data`. Wired to `uploadService.upload(data:...)` in
    /// `configure`; tests inject a fake that skips the network entirely.
    var uploadHandler: ((Data, String, String, String?) async throws -> UploadResult)?

    /// Exports a `PHAsset.localIdentifier` to bytes. Defaults to the real PhotoKit-backed
    /// exporter; tests inject a fake.
    var assetExporter: PhotoAssetExporting

    // MARK: - Dependencies

    weak var driveService: DriveService?
    weak var uploadService: UploadService?

    /// Wires `folderResolver`/`uploadHandler` to real dependencies. Call once at launch.
    func configure(driveService: DriveService, uploadService: UploadService) {
        self.driveService = driveService
        self.uploadService = uploadService
        folderResolver = { [weak driveService] name, parentID in
            guard let driveService else { throw DriveError.notAuthenticated }
            return try await driveService.ensureFolder(named: name, parentID: parentID)
        }
        uploadHandler = { [weak uploadService] data, fileName, mimeType, parentFolderID in
            guard let uploadService else { throw UploadError.notAuthenticated }
            return try await uploadService.upload(data: data, fileName: fileName, mimeType: mimeType,
                                                  parentFolderID: parentFolderID, reportsProgress: false)
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
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.neutrino.drive.photosync.pathmonitor")
    private var backgroundTask: BGProcessingTask?

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

    var failedEntries: [PhotoSyncQueue.Entry] { queue.failed }

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
            await drain(ignoringPowerConstraint: false)
        }
    }

    /// Registers the `BGProcessingTask` handler. Must be called before the app finishes
    /// launching. No-ops when the feature flag is off.
    func registerBackgroundTask() {
        guard FeatureFlags.photoAutoSync else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: nil) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            self?.handleBackgroundTask(processingTask)
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
            self.status = status == .limited ? .permissionLimited : .idle
            startObservingIfNeeded()
            startNetworkMonitoring()
            await captureInitialChangeToken()
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
        pathMonitor.cancel()
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

    private func startNetworkMonitoring() {
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

    // MARK: - Change enqueue (pure — testable without PhotoKit)

    /// Returns the identifiers from `assets` that are not already known to `queue` and were
    /// created on/after `anchorDate`, oldest-first.
    static func newIdentifiers(from assets: [PhotoAssetProviding], anchorDate: Date,
                               includeVideos: Bool, queue: PhotoSyncQueue) -> [(id: String, creationDate: Date)] {
        assets
            .filter { includeVideos || $0.mediaType != .video }
            .compactMap { asset -> (String, Date)? in
                guard let created = asset.creationDate, created >= anchorDate else { return nil }
                guard !queue.contains(id: asset.localIdentifier) else { return nil }
                return (asset.localIdentifier, created)
            }
            .sorted { $0.1 < $1.1 }
    }

    /// Enqueues every asset in `assets` that passes `newIdentifiers`, persists the queue, and
    /// returns the number newly enqueued.
    @discardableResult
    func enqueueIfNeeded(_ assets: [PhotoAssetProviding]) -> Int {
        let anchor = defaults.object(forKey: Keys.anchorDate) as? Date ?? .distantFuture
        let newOnes = Self.newIdentifiers(from: assets, anchorDate: anchor,
                                          includeVideos: includeVideos, queue: queue)
        for entry in newOnes {
            queue.enqueue(id: entry.id, creationDate: entry.creationDate)
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
        let cutoff = max(anchor, lastSync)

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", cutoff as NSDate)
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PhotoAssetProviding] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        enqueueIfNeeded(assets)
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

        guard hasAccessTokenProvider() else {
            status = .pausedNotAuthenticated
            return false
        }
        guard hasStoredKeysProvider() else {
            status = .pausedMissingKey
            return false
        }
        if wifiOnly && (!isOnWiFi || isNetworkExpensive) {
            status = .waitingForWiFi
            return false
        }
        if !ignoringPowerConstraint && whileChargingOnly && batteryStateProvider() == .unplugged {
            status = .waitingToCharge
            return false
        }
        if isBackgroundExpired != nil && isLowPowerModeEnabledProvider() {
            // Low Power Mode pauses background drains only; foreground "Sync Now" still works.
            return false
        }

        isDraining = true
        defer { isDraining = false }

        var uploadedAny = false
        let total = queue.drainable().count
        var index = 0
        while let entry = queue.drainable().first {
            if let isBackgroundExpired, isBackgroundExpired() { break }
            index += 1
            status = .uploading(name: entry.id, index: index, total: total)
            await performUpload(entry)
            uploadedAny = true
        }

        refreshCounts()
        if pendingCount == 0 {
            status = failedCount > 0 ? .failed(count: failedCount) : .idle
        }
        return uploadedAny
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

    /// Uploads `export`, resolving the destination folder first. If the upload fails with a
    /// 404 (the cached folder ID was deleted/trashed server-side), the cached ID is cleared
    /// and resolution + upload are retried exactly once before giving up.
    private func uploadWithFolderRetry(export: PhotoExport, entry: PhotoSyncQueue.Entry) async throws {
        let folderID = try await resolveDestinationFolder()
        do {
            _ = try await upload(export: export, parentFolderID: folderID)
        } catch UploadError.serverError(let code) where code == 404 {
            defaults.removeObject(forKey: Keys.folderID)
            let retriedFolderID = try await resolveDestinationFolder()
            _ = try await upload(export: export, parentFolderID: retriedFolderID)
        }
        queue.markCompleted(id: entry.id)
        lastSyncedAt = Date()
        defaults.set(lastSyncedAt, forKey: Keys.lastSuccessfulSync)
        persistQueue()
    }

    private func upload(export: PhotoExport, parentFolderID: String?) async throws -> UploadResult {
        guard let uploadHandler else { throw UploadError.notAuthenticated }
        return try await uploadHandler(export.data, export.fileName, export.mimeType, parentFolderID)
    }

    private func isPermanent(_ error: UploadError) -> Bool {
        if case .serverError(let code) = error {
            if code == 408 || code == 429 { return false }
            return (400..<500).contains(code)
        }
        return false
    }

    // MARK: - Folder resolution

    /// Resolves the destination folder ID: cached value if present, otherwise find-or-create
    /// via `folderResolver`, caching the result for next time.
    func resolveDestinationFolder() async throws -> String {
        if let cached = defaults.string(forKey: Keys.folderID) {
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

    private func handleBackgroundTask(_ task: BGProcessingTask) {
        scheduleBackgroundTask()   // the system grants exactly one run per submission
        var expired = false
        task.expirationHandler = { [weak self] in
            expired = true
            Task { @MainActor in
                self?.persistQueueNow()
                task.setTaskCompleted(success: false)
            }
        }
        Task {
            await runCatchUpScan()
            await drain(ignoringPowerConstraint: false, isBackgroundExpired: { expired })
            if !expired {
                task.setTaskCompleted(success: true)
            }
        }
    }

    private func persistQueueNow() {
        queueStore.save(queue)
    }

    func scheduleBackgroundTask(earliestBeginDate: Date = Date().addingTimeInterval(60)) {
        guard FeatureFlags.photoAutoSync, isEnabled else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = whileChargingOnly
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("scheduleBackgroundTask failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Test Seams

    #if DEBUG
    func debugIsCompleted(_ id: String) -> Bool { queue.completed.contains(id) }
    func debugFailedEntry(_ id: String) -> PhotoSyncQueue.Entry? { queue.failed.first(where: { $0.id == id }) }
    func debugPendingEntry(_ id: String) -> PhotoSyncQueue.Entry? { queue.pending.first(where: { $0.id == id }) }
    #endif
}

// MARK: - PHPhotoLibraryChangeObserver

extension PhotoSyncService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            // Live observation: fetch assets created since the anchor date and enqueue any
            // not already known. The persistent-change catch-up (run on launch/foreground)
            // covers the gap while the app was not running; this covers changes while it is.
            let anchor = self.defaults.object(forKey: Keys.anchorDate) as? Date ?? .distantFuture
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@", anchor as NSDate)
            let result = PHAsset.fetchAssets(with: options)
            var assets: [PhotoAssetProviding] = []
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
            self.enqueueIfNeeded(assets)
            await self.drain(ignoringPowerConstraint: false)
        }
    }
}

