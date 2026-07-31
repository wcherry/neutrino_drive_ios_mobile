import Foundation
import os.log

// MARK: - PhotoSyncQueue

/// Persistent, deduplicated queue of photo-library assets waiting to be uploaded.
///
/// Entries are keyed by `PHAsset.localIdentifier`. Dedup is enforced across all three
/// collections (`pending`, `completed`, `failed`) — the single guarantee that a photo is
/// never uploaded twice, and the reason the PhotoKit catch-up scan can be run liberally
/// (see `PhotoSyncService`).
struct PhotoSyncQueue: Codable, Equatable {

    // MARK: - Entry

    struct Entry: Codable, Identifiable, Equatable {
        /// `PHAsset.localIdentifier`.
        let id: String
        let creationDate: Date
        var attempts: Int
        var lastError: String?
        var nextAttemptAfter: Date?

        init(id: String, creationDate: Date, attempts: Int = 0,
             lastError: String? = nil, nextAttemptAfter: Date? = nil) {
            self.id = id
            self.creationDate = creationDate
            self.attempts = attempts
            self.lastError = lastError
            self.nextAttemptAfter = nextAttemptAfter
        }
    }

    // MARK: - Collections

    var pending: [Entry] = []
    var completed: Set<String> = []
    var failed: [Entry] = []

    // MARK: - Retry schedule

    /// Delay applied after the Nth failed attempt (1-indexed): 30s, 2m, 10m, 1h, 6h.
    /// After `maxAttempts` failures the entry moves permanently to `failed`.
    static let backoffSchedule: [TimeInterval] = [30, 120, 600, 3600, 21600]
    static let maxAttempts = backoffSchedule.count

    // MARK: - Init

    init(pending: [Entry] = [], completed: Set<String> = [], failed: [Entry] = []) {
        self.pending = pending
        self.completed = completed
        self.failed = failed
    }

    // MARK: - Dedup

    /// True if `id` already exists in any of the three collections.
    func contains(id: String) -> Bool {
        pending.contains(where: { $0.id == id })
            || completed.contains(id)
            || failed.contains(where: { $0.id == id })
    }

    // MARK: - Enqueue

    /// Adds a new pending entry unless `id` already exists in `pending`, `completed`, or
    /// `failed`. Returns `true` if the entry was newly added.
    @discardableResult
    mutating func enqueue(id: String, creationDate: Date) -> Bool {
        guard !contains(id: id) else { return false }
        pending.append(Entry(id: id, creationDate: creationDate))
        return true
    }

    // MARK: - Draining

    /// Pending entries eligible for an attempt right now (backoff has elapsed, or never
    /// attempted), ordered oldest-`creationDate`-first so a backlog drains in capture order.
    func drainable(asOf now: Date = Date()) -> [Entry] {
        pending
            .filter { ($0.nextAttemptAfter ?? .distantPast) <= now }
            .sorted { $0.creationDate < $1.creationDate }
    }

    // MARK: - Outcomes

    /// Moves `id` from `pending` to `completed`.
    mutating func markCompleted(id: String) {
        pending.removeAll { $0.id == id }
        completed.insert(id)
    }

    /// Records a failed attempt for `id`.
    ///
    /// - Parameter permanent: `true` for errors that will never succeed on retry (4xx other
    ///   than 408/429, or an oversized asset) — the entry moves to `failed` immediately
    ///   regardless of `attempts`. Otherwise the backoff schedule advances; once `attempts`
    ///   reaches `maxAttempts` the entry also moves to `failed`.
    mutating func markFailed(id: String, error: String, permanent: Bool = false) {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }
        var entry = pending[idx]
        entry.attempts += 1
        entry.lastError = error

        if permanent || entry.attempts >= Self.maxAttempts {
            entry.nextAttemptAfter = nil
            pending.remove(at: idx)
            failed.append(entry)
        } else {
            let delay = Self.backoffSchedule[min(entry.attempts - 1, Self.backoffSchedule.count - 1)]
            entry.nextAttemptAfter = Date().addingTimeInterval(delay)
            pending[idx] = entry
        }
    }

    /// Moves every `failed` entry back to `pending` with a clean retry state, for the
    /// Settings screen's "Retry Failed" action.
    mutating func retryAllFailed() {
        for var entry in failed {
            entry.attempts = 0
            entry.lastError = nil
            entry.nextAttemptAfter = nil
            pending.append(entry)
        }
        failed.removeAll()
    }

    // MARK: - Compaction

    /// Drops `completed` identifiers whose asset no longer exists in the photo library
    /// (per `validIdentifiers`), keeping the ledger from growing without bound.
    mutating func compact(keepingIdentifiers validIdentifiers: Set<String>) {
        completed = completed.intersection(validIdentifiers)
    }
}

// MARK: - PhotoSyncQueueStore

/// Persists a `PhotoSyncQueue` to disk as JSON.
final class PhotoSyncQueueStore {

    private let fileURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "PhotoSyncQueueStore")

    /// `fileURL` defaults to `Application Support/photo-sync-queue.json`. Tests can inject a
    /// scratch location instead of touching the real Application Support directory.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = dir.appendingPathComponent("photo-sync-queue.json")
        }
    }

    func load() -> PhotoSyncQueue {
        guard let data = try? Data(contentsOf: fileURL),
              let queue = try? JSONDecoder.photoSync.decode(PhotoSyncQueue.self, from: data) else {
            return PhotoSyncQueue()
        }
        return queue
    }

    func save(_ queue: PhotoSyncQueue) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder.photoSync.encode(queue)
            try data.write(to: fileURL, options: .atomic)
            excludeFromBackup()
        } catch {
            logger.error("PhotoSyncQueueStore save failed: \(error, privacy: .public)")
        }
    }

    /// Excludes the queue file from iCloud/iTunes backup — it is a local work queue, not
    /// user data worth preserving across a restore.
    private func excludeFromBackup() {
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - Shared JSON coding

extension JSONEncoder {
    static let photoSync: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let photoSync: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
