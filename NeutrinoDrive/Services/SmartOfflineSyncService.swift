import Foundation
import Network
import UIKit
import os.log

// MARK: - SmartOfflineSyncService

/// Automatically caches the files this user actually uses, within a storage budget, so they
/// open with no network — `mvp.md` Phase 5 "Smart Offline Sync".
///
/// Ranking comes from `FileAccessTracker` (local, because the backend cannot supply an access
/// signal — see that type for the evidence). This service owns the *policy*: what to fetch,
/// what to throw away, and when it is acceptable to spend the user's data and disk at all.
///
/// ## Three rules this is built around
///
/// 1. **Never evict something the user pinned.** "Make Available Offline" is an explicit
///    instruction. An automatic cache that can delete it is not a cache, it is a bug that only
///    manifests on a plane. Eviction considers `isManaged` entries exclusively.
/// 2. **The budget governs the automatic cache only.** Pinned files sit outside it. Folding
///    them in would mean a user who pins 3 GB silently disables the feature, or that raising
///    the budget to accommodate pins lets the automatic cache grow to match — both surprising.
///    Settings presents the two figures separately for the same reason.
/// 3. **Never spend data or power the user did not agree to.** Defaults are Wi-Fi-only and
///    on-battery-allowed, matching `PhotoSyncService`, and the same `NWPathMonitor` +
///    `UIDevice.batteryState` gating is reused rather than reinvented.
///
/// ## What it does not do
///
/// It does not run in the background. There is no `BGTaskScheduler` registration here: photo
/// sync already owns a processing task, and adding a second competing identifier for a
/// convenience cache is not a good trade against the app's background budget. Sync runs when
/// the app is foregrounded and after an access is recorded. That is a deliberate limit, not an
/// oversight, and is recorded as such in the plan.
@MainActor
final class SmartOfflineSyncService: ObservableObject {

    // MARK: - Status

    enum Status: Equatable {
        case idle
        case waitingForWiFi
        case waitingForPower
        case syncing(remaining: Int)
        case disabled

        var displayText: String {
            switch self {
            case .idle:                  return "Up to date"
            case .waitingForWiFi:        return "Waiting for Wi-Fi"
            case .waitingForPower:       return "Waiting for charger"
            case .syncing(let n):        return "Caching \(n) file\(n == 1 ? "" : "s")…"
            case .disabled:              return "Off"
            }
        }
    }

    // MARK: - Published

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?

    /// Live network state, updated by `NWPathMonitor`. Tests set it directly rather than faking
    /// a real path — the same approach `PhotoSyncService` takes.
    @Published var isOnWiFi: Bool = true

    // MARK: - Settings

    private enum Keys {
        static let enabled          = "smartOffline.enabled"
        static let budgetBytes      = "smartOffline.budgetBytes"
        static let wifiOnly         = "smartOffline.wifiOnly"
        static let whileChargingOnly = "smartOffline.whileChargingOnly"
    }

    /// 500 MB. Large enough to be useful, small enough that a user who never opens Settings is
    /// not surprised by what the app took.
    nonisolated static let defaultBudgetBytes: Int64 = 500 * 1024 * 1024

    static let budgetOptions: [Int64] = [
        100 * 1024 * 1024, 500 * 1024 * 1024,
        1024 * 1024 * 1024, 5 * 1024 * 1024 * 1024,
    ]

    private let defaults: UserDefaults

    /// Off until the user turns it on. Silently filling a phone with files it decided were
    /// interesting is not a default anyone asked for, and the storage cost is the user's.
    var isEnabled: Bool {
        get { FeatureFlags.smartOfflineSync && (defaults.object(forKey: Keys.enabled) as? Bool ?? false) }
        set { defaults.set(newValue, forKey: Keys.enabled); objectWillChange.send() }
    }

    var budgetBytes: Int64 {
        get { (defaults.object(forKey: Keys.budgetBytes) as? Int64) ?? Self.defaultBudgetBytes }
        set { defaults.set(newValue, forKey: Keys.budgetBytes); objectWillChange.send() }
    }

    var wifiOnly: Bool {
        get { defaults.object(forKey: Keys.wifiOnly) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.wifiOnly); objectWillChange.send() }
    }

    var whileChargingOnly: Bool {
        get { defaults.object(forKey: Keys.whileChargingOnly) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.whileChargingOnly); objectWillChange.send() }
    }

    // MARK: - Dependencies

    private let tracker: FileAccessTracker
    private let pathMonitor = NWPathMonitor()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "SmartOfflineSyncService")

    // MARK: - Init

    init(tracker: FileAccessTracker = .shared,
         defaults: UserDefaults = .standard,
         startMonitoring: Bool = true) {
        self.tracker = tracker
        self.defaults = defaults
        if startMonitoring { beginPathMonitoring() }
    }

    private func beginPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnWiFi = path.usesInterfaceType(.wifi) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.neutrino.drive.smartoffline.path"))
    }

    // MARK: - Constraints

    /// Whether the device is plugged in. Reading `batteryState` requires monitoring to be
    /// enabled; enabling it here rather than at launch keeps the cost to users of this feature.
    nonisolated static func isCharging() -> Bool {
        MainActor.assumeIsolated {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            return state == .charging || state == .full
        }
    }

    /// The gate, factored out so it can be tested without a network or a battery.
    ///
    /// `isCharging` is a parameter rather than a direct read for exactly that reason — the
    /// simulator always reports `.unknown`, so a service that read it inline would be
    /// untestable and would behave differently on a device than in a test.
    nonisolated static func constraintsSatisfied(enabled: Bool,
                                     wifiOnly: Bool,
                                     onWiFi: Bool,
                                     whileChargingOnly: Bool,
                                     isCharging: Bool) -> Bool {
        guard FeatureFlags.smartOfflineSync, enabled else { return false }
        if wifiOnly && !onWiFi { return false }
        if whileChargingOnly && !isCharging { return false }
        return true
    }

    func currentStatusForConstraints(isCharging: Bool) -> Status {
        guard FeatureFlags.smartOfflineSync, isEnabled else { return .disabled }
        if wifiOnly && !isOnWiFi { return .waitingForWiFi }
        if whileChargingOnly && !isCharging { return .waitingForPower }
        return .idle
    }

    // MARK: - Plan

    /// What a sync pass would do, computed as a pure function of its inputs.
    struct Plan: Equatable {
        /// Managed file IDs to delete, lowest-scoring first.
        var toEvict: [String] = []
        /// Records to download, highest-scoring first.
        var toDownload: [FileAccessRecord] = []
    }

    /// Decides what to cache and what to drop.
    ///
    /// Pure and static so the policy — the part that can silently fill a disk or delete the
    /// wrong file — is testable without a network, a filesystem, or a clock.
    ///
    /// - Parameter existing: everything currently offline, pinned and managed alike. Pinned
    ///   entries are read only to avoid re-downloading them; they are never evicted and never
    ///   counted against the budget.
    nonisolated static func makePlan(candidates: [FileAccessRecord],
                         existing: [OfflineFile],
                         budgetBytes: Int64,
                         maxDownloadsPerPass: Int = 10,
                         now: Date = Date()) -> Plan {

        var plan = Plan()

        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let managed = existing.filter(\.isManaged)

        // Rank *managed* entries by the same score used to choose downloads, so eviction and
        // admission agree. An entry with no access record scores 0 and is evicted first, which
        // is the right treatment for something cached before the user's habits changed.
        let scoreByID = Dictionary(candidates.map { ($0.id, score(for: $0, now: now)) },
                                   uniquingKeysWith: { a, _ in a })
        func managedScore(_ file: OfflineFile) -> Double { scoreByID[file.id] ?? 0 }

        var budgetUsed = managed.reduce(0) { $0 + $1.sizeBytes }
        var survivors = managed.sorted {
            let a = managedScore($0), b = managedScore($1)
            return a == b ? $0.id < $1.id : a > b
        }

        // Wanted: highest-scoring records that are not already offline and have a known size.
        // An unknown size is skipped rather than guessed — admitting a file of unknown size is
        // how a budget gets blown.
        let wanted = candidates
            .filter { existingByID[$0.id] == nil }
            .filter { ($0.sizeBytes ?? 0) > 0 }
            .sorted {
                let a = score(for: $0, now: now), b = score(for: $1, now: now)
                return a == b ? $0.id < $1.id : a > b
            }

        for record in wanted {
            guard plan.toDownload.count < maxDownloadsPerPass else { break }
            let size = record.sizeBytes ?? 0
            // A single file larger than the whole budget can never be admitted; skip rather
            // than evicting everything in a doomed attempt to fit it.
            guard size <= budgetBytes else { continue }

            let candidateScore = score(for: record, now: now)
            var evictions: [String] = []
            var projected = budgetUsed

            // Evict the weakest survivors until this fits — but only ones this candidate
            // actually outranks. Otherwise a sync pass would churn, dropping a better file to
            // make room for a worse one.
            var index = survivors.count - 1
            while projected + size > budgetBytes && index >= 0 {
                let victim = survivors[index]
                guard managedScore(victim) < candidateScore else { break }
                evictions.append(victim.id)
                projected -= victim.sizeBytes
                index -= 1
            }

            guard projected + size <= budgetBytes else { continue }

            plan.toEvict.append(contentsOf: evictions)
            survivors.removeAll { evictions.contains($0.id) }
            budgetUsed = projected + size
            plan.toDownload.append(record)
        }

        return plan
    }

    nonisolated private static func score(for record: FileAccessRecord, now: Date) -> Double {
        FileAccessTracker.score(for: record, now: now)
    }

    // MARK: - Sync

    /// Runs one pass: evict what the plan says to evict, then download what it says to cache.
    ///
    /// Downloads run one at a time and re-check constraints between each, so unplugging or
    /// leaving Wi-Fi stops the pass promptly instead of at the end of a queue.
    func sync(offlineService: OfflineService,
              downloadService: DownloadService,
              driveService: DriveService,
              isCharging: Bool = SmartOfflineSyncService.isCharging()) async {

        guard Self.constraintsSatisfied(enabled: isEnabled,
                                        wifiOnly: wifiOnly,
                                        onWiFi: isOnWiFi,
                                        whileChargingOnly: whileChargingOnly,
                                        isCharging: isCharging) else {
            status = currentStatusForConstraints(isCharging: isCharging)
            return
        }

        tracker.prune()
        let plan = Self.makePlan(candidates: tracker.rankedRecords(),
                                 existing: offlineService.offlineFiles,
                                 budgetBytes: budgetBytes)

        for id in plan.toEvict {
            offlineService.evictManaged(fileID: id)
        }

        guard !plan.toDownload.isEmpty else {
            status = .idle
            lastSyncedAt = Date()
            return
        }

        var remaining = plan.toDownload.count
        for record in plan.toDownload {
            guard Self.constraintsSatisfied(enabled: isEnabled,
                                            wifiOnly: wifiOnly,
                                            onWiFi: isOnWiFi,
                                            whileChargingOnly: whileChargingOnly,
                                            isCharging: isCharging) else {
                status = currentStatusForConstraints(isCharging: isCharging)
                return
            }
            status = .syncing(remaining: remaining)

            let item = DriveItem(id: record.id,
                                 name: record.name,
                                 type: .file,
                                 parentID: nil,
                                 size: record.sizeBytes,
                                 modifiedAt: record.lastAccessed,
                                 isTrashed: false,
                                 isShared: false,
                                 mimeType: record.mimeType)
            do {
                try await offlineService.makeAvailableOffline(item: item,
                                                              downloadService: downloadService,
                                                              isManaged: true)
            } catch {
                // One failure must not abort the pass — a single deleted or permission-changed
                // file would otherwise block every other candidate forever.
                logger.error("smart cache failed for \(record.id, privacy: .public): \(error, privacy: .public)")
                lastError = error.localizedDescription
            }
            remaining -= 1
        }

        status = .idle
        lastSyncedAt = Date()
    }
}
