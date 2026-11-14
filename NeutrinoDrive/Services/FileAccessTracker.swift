import Foundation
import os.log

// MARK: - FileAccessRecord

/// One file's local access history.
struct FileAccessRecord: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var mimeType: String?
    var sizeBytes: Int64?
    var accessCount: Int
    var lastAccessed: Date
}

// MARK: - FileAccessTracker

/// Records, locally, which files this user actually opens and how recently — the signal that
/// `SmartOfflineSyncService` ranks candidates by.
///
/// ## Why this is local, and not the backend's `/quick-access` or `/activity`
///
/// The obvious move is to reuse a server-side signal. I read both candidate endpoints in the
/// Rust source before writing this, and **neither can supply one**. Three independent reasons:
///
/// 1. **The activity log is never written for file access.** `ActivityService.log` →
///    `ActivityRepository.insert_entry` has exactly three callers in the whole backend, in
///    `src/drive/comments/service.rs` and `src/drive/suggestions/service.rs`. Nothing in
///    `src/drive/storage/api.rs` logs a view, an open, or a download. So
///    `GET /files/{id}/activity` reports comment and suggestion events and says nothing about
///    how often a file is opened.
///
/// 2. **`/quick-access`'s scoring query is broken and fails silently.**
///    `src/drive/priority/service.rs` groups on `al.action_type`, but the column in
///    `file_activity_log` is `action`. The `sql_query` therefore errors, and
///    `.load(conn).unwrap_or_default()` swallows the error into an empty vec, which takes the
///    `if scored.is_empty()` fallback branch. The endpoint returns *"most recently updated"* in
///    every case; the frequency scoring it appears to implement has never executed.
///
/// 3. **Its limit is hardcoded** to 8 (`src/drive/priority/api.rs`), not a query parameter.
///
/// Those are reported as findings; fixing them is backend work and out of scope here.
///
/// ## Why local is the better answer anyway
///
/// Even with those endpoints working, this would belong on the device. "Which files this user
/// opens, and how often" is precisely the behavioural metadata an end-to-end-encrypted product
/// exists to withhold — shipping it to the server to power a *client-side* cache would trade
/// away the product's main promise for a convenience the client can compute itself.
///
/// The local signal is also strictly richer: it sees File Provider materializations and opens
/// of already-cached offline files, neither of which produces a server request at all.
///
/// ## Scoring
///
/// `score = accessCount·frequencyWeight + recencyWeight / (1 + daysSinceLastAccess)`
///
/// Deliberately simple and explainable rather than tuned. Frequency accumulates without bound
/// so a genuinely habitual file wins; recency decays hyperbolically so today's file outranks a
/// file opened twice last month, but a file opened forty times does not lose to something
/// touched once this morning.
final class FileAccessTracker {

    // MARK: - Shared

    static let shared = FileAccessTracker()

    // MARK: - Tuning

    static let frequencyWeight = 1.0
    static let recencyWeight = 5.0

    /// Records older than this with a single access are pruned, so the store cannot grow
    /// without limit on a long-lived install.
    static let staleAfterDays = 90.0
    /// Hard ceiling on retained records, applied after pruning, keeping the highest scores.
    static let maxRecords = 500

    // MARK: - State

    private let storageURL: URL
    private let queue = DispatchQueue(label: "com.neutrino.drive.fileaccess")
    private var records: [String: FileAccessRecord]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "FileAccessTracker")

    // MARK: - Init

    /// - Parameter storageDirectory: tests inject a temp directory so they never touch the real
    ///   Application Support container.
    init(storageDirectory: URL? = nil) {
        let dir = storageDirectory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("file-access.json")
        self.records = Self.load(from: storageURL)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SmartOffline", isDirectory: true)
    }

    private static func load(from url: URL) -> [String: FileAccessRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([FileAccessRecord].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    // MARK: - Recording

    /// Note an open of `item`.
    ///
    /// A no-op when `FeatureFlags.smartOfflineSync` is off — the flag means "record nothing",
    /// not merely "do not act on it". A disabled feature that quietly builds a behavioural
    /// profile would be exactly the wrong default for this product.
    func recordAccess(item: DriveItem) {
        recordAccess(fileID: item.id, name: item.name, mimeType: item.mimeType,
                     sizeBytes: item.size)
    }

    func recordAccess(fileID: String,
                      name: String,
                      mimeType: String?,
                      sizeBytes: Int64?,
                      at date: Date = Date()) {
        guard FeatureFlags.smartOfflineSync else { return }
        queue.sync {
            var record = records[fileID] ?? FileAccessRecord(
                id: fileID, name: name, mimeType: mimeType, sizeBytes: sizeBytes,
                accessCount: 0, lastAccessed: date
            )
            record.name = name
            if let mimeType { record.mimeType = mimeType }
            // Never overwrite a known size with nil — a listing that omits size would
            // otherwise erase what a previous download established.
            if let sizeBytes { record.sizeBytes = sizeBytes }
            record.accessCount += 1
            record.lastAccessed = date
            records[fileID] = record
            persistLocked()
        }
    }

    // MARK: - Queries

    var allRecords: [FileAccessRecord] {
        queue.sync { Array(records.values) }
    }

    func record(for fileID: String) -> FileAccessRecord? {
        queue.sync { records[fileID] }
    }

    /// Candidates ranked best-first.
    func rankedRecords(now: Date = Date()) -> [FileAccessRecord] {
        queue.sync {
            records.values
                .sorted {
                    let a = Self.score(for: $0, now: now), b = Self.score(for: $1, now: now)
                    // Tie-break on id so the order is deterministic and tests are not flaky.
                    return a == b ? $0.id < $1.id : a > b
                }
        }
    }

    static func score(for record: FileAccessRecord, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(record.lastAccessed) / 86_400)
        return Double(record.accessCount) * frequencyWeight + recencyWeight / (1 + days)
    }

    // MARK: - Maintenance

    /// Drops single-access records older than `staleAfterDays`, then caps the store at
    /// `maxRecords` by score.
    func prune(now: Date = Date()) {
        queue.sync {
            let cutoff = now.addingTimeInterval(-Self.staleAfterDays * 86_400)
            records = records.filter { !($0.value.accessCount <= 1 && $0.value.lastAccessed < cutoff) }
            if records.count > Self.maxRecords {
                let keep = records.values
                    .sorted { Self.score(for: $0, now: now) > Self.score(for: $1, now: now) }
                    .prefix(Self.maxRecords)
                records = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
            }
            persistLocked()
        }
    }

    /// Forgets everything. Called on sign-out and on key removal, so an access history does not
    /// outlive the session that produced it.
    func reset() {
        queue.sync {
            records = [:]
            try? FileManager.default.removeItem(at: storageURL)
        }
    }

    // MARK: - Persistence

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(Array(records.values))
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("persist failed: \(error, privacy: .public)")
        }
    }
}
