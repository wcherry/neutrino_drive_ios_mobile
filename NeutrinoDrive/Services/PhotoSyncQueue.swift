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
        /// `PHAsset.modificationDate` — when the picture was last edited, which for an
        /// unedited one is its capture date.
        ///
        /// Optional, and decoded with `decodeIfPresent` by the synthesised initialiser, so a
        /// queue file written before this field existed still loads. An entry from such a file
        /// stamps its creation date for both dates, which is the right answer for every photo
        /// that was never edited and a harmless one for the rest.
        let modificationDate: Date?
        var attempts: Int
        var lastError: String?
        var nextAttemptAfter: Date?

        init(id: String, creationDate: Date, modificationDate: Date? = nil, attempts: Int = 0,
             lastError: String? = nil, nextAttemptAfter: Date? = nil) {
            self.id = id
            self.creationDate = creationDate
            self.modificationDate = modificationDate
            self.attempts = attempts
            self.lastError = lastError
            self.nextAttemptAfter = nextAttemptAfter
        }
    }

    // MARK: - CompletedUpload

    /// What the ledger knows about an asset that finished uploading.
    ///
    /// A record rather than a bare identifier because the Drive file id is the one thing
    /// needed to go back and correct a file after the fact — the capture-date patch in
    /// `PhotoSyncService`, and anything else that has to reach the file this asset became.
    /// Before issue #31 the ledger was a `Set<String>` and threw the id away, which is what
    /// made repairing history a filename-matching exercise.
    struct CompletedUpload: Codable, Equatable {
        /// The Drive file this asset was uploaded as, or `nil` for a completion recorded
        /// before the ledger kept one. See the migration in ``PhotoSyncQueue/init(from:)``.
        var fileID: String?

        init(fileID: String? = nil) {
            self.fileID = fileID
        }
    }

    // MARK: - Collections

    var pending: [Entry] = []
    /// `PHAsset.localIdentifier` → what became of it. Also the dedup ledger: membership, not
    /// the value, is what stops a photo being uploaded twice.
    var completed: [String: CompletedUpload] = [:]
    var failed: [Entry] = []

    // MARK: - Retry schedule

    /// Delay applied after the Nth failed attempt (1-indexed): 30s, 2m, 10m, 1h, 6h.
    /// After `maxAttempts` failures the entry moves permanently to `failed`.
    static let backoffSchedule: [TimeInterval] = [30, 120, 600, 3600, 21600]
    static let maxAttempts = backoffSchedule.count

    // MARK: - Init

    init(pending: [Entry] = [], completed: [String: CompletedUpload] = [:], failed: [Entry] = []) {
        self.pending = pending
        self.completed = completed
        self.failed = failed
    }

    // MARK: - Decoding (with migration)

    private enum CodingKeys: String, CodingKey {
        case pending, completed, failed
    }

    /// Hand-written so the `completed` ledger can be read in either of its two shapes.
    ///
    /// Until issue #31 it was encoded as a bare array of identifiers (a `Set<String>`). An
    /// install upgrading across that change has one of those on disk, and decoding it as the
    /// new dictionary throws — which `PhotoSyncQueueStore.load` turns into an *empty* queue,
    /// i.e. a dedup ledger that has forgotten every photo it ever uploaded and a library that
    /// re-uploads itself. Legacy entries arrive with no file id, which is the truth about
    /// them: nothing recorded one at the time.
    ///
    /// Only `Decodable` is hand-written; the encoder stays synthesised and always writes the
    /// new shape.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pending = try container.decodeIfPresent([Entry].self, forKey: .pending) ?? []
        failed  = try container.decodeIfPresent([Entry].self, forKey: .failed) ?? []

        if let ledger = try? container.decode([String: CompletedUpload].self, forKey: .completed) {
            completed = ledger
        } else {
            let legacy = try container.decodeIfPresent([String].self, forKey: .completed) ?? []
            completed = legacy.reduce(into: [:]) { ledger, id in
                ledger[id] = CompletedUpload()
            }
        }
    }

    // MARK: - Dedup

    /// True if `id` already exists in any of the three collections.
    func contains(id: String) -> Bool {
        pending.contains(where: { $0.id == id })
            || completed[id] != nil
            || failed.contains(where: { $0.id == id })
    }

    // MARK: - Enqueue

    /// Adds a new pending entry unless `id` already exists in `pending`, `completed`, or
    /// `failed`. Returns `true` if the entry was newly added.
    @discardableResult
    mutating func enqueue(id: String, creationDate: Date, modificationDate: Date? = nil) -> Bool {
        guard !contains(id: id) else { return false }
        pending.append(Entry(id: id, creationDate: creationDate, modificationDate: modificationDate))
        return true
    }

    // MARK: - Draining

    /// Pending entries eligible for an attempt right now (backoff has elapsed, or never
    /// attempted), ordered oldest-`creationDate`-first so a backlog drains in capture order.
    ///
    /// - Parameter newerThan: entries created before this date sort *after* every entry
    ///   created on or after it, each group still in capture order. This is what keeps a
    ///   backfill of the existing library (see `PhotoSyncService.backfillDays`) from
    ///   starving the photo the user took a minute ago: without it, a one-year window puts
    ///   thousands of old assets ahead of everything new. Defaults to `.distantPast`, which
    ///   places every entry in the first group — i.e. plain capture order.
    func drainable(asOf now: Date = Date(), newerThan boundary: Date = .distantPast) -> [Entry] {
        pending
            .filter { ($0.nextAttemptAfter ?? .distantPast) <= now }
            .sorted { lhs, rhs in
                let lhsIsBacklog = lhs.creationDate < boundary
                let rhsIsBacklog = rhs.creationDate < boundary
                if lhsIsBacklog != rhsIsBacklog { return !lhsIsBacklog }
                return lhs.creationDate < rhs.creationDate
            }
    }

    // MARK: - Outcomes

    /// Moves `id` from `pending` to `completed`, recording the Drive file it became.
    ///
    /// - Parameter fileID: the uploaded file's id. `nil` only for a caller that genuinely does
    ///   not have one; every real upload does, and throwing it away is what issue #31 was
    ///   partly about.
    mutating func markCompleted(id: String, fileID: String? = nil) {
        pending.removeAll { $0.id == id }
        completed[id] = CompletedUpload(fileID: fileID)
    }

    /// The Drive file `id` was uploaded as, or `nil` if it has not completed or completed
    /// before the ledger recorded one.
    func completedFileID(for id: String) -> String? {
        completed[id]?.fileID
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
        completed = completed.filter { validIdentifiers.contains($0.key) }
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
