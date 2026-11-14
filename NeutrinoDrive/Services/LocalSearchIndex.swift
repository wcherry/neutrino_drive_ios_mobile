import Foundation
import os.log

// MARK: - LocalSearchIndex

/// The on-device search index — every Drive file this device knows about, tokenized for
/// prefix search, kept in memory and persisted to disk so it survives relaunch without a
/// re-sync.
///
/// Deliberately close to the web app's IndexedDB-backed `docs`/`tokens` stores and its
/// `IndexEngine.query` (`packages/search/src/db.ts` / `engine.ts` in the `neutrino` repo) —
/// same scoring, same prefix semantics — so a snapshot exported here imports there and vice
/// versa. See `agent_docs/search.md` for the architecture this mirrors, and
/// `SearchIndexSyncService` for how snapshots move between devices.
///
/// `@MainActor` rather than an `actor`: every caller (`SearchService`, `SearchIndexSyncService`,
/// `FileBrowserView`) already runs on the main actor, and the `DriveItem` state feeding this is
/// main-actor-bound too, so a separate isolation domain would only add hops.
@MainActor
final class LocalSearchIndex {

    static let shared = LocalSearchIndex()

    // MARK: - Tuning (matches packages/search/src/engine.ts)

    private static let titleWeight = 3
    private static let maxResults = 20
    /// Query terms shorter than this are dropped rather than prefix-matched — a one or two
    /// letter prefix matches a large share of the index for a result nobody wanted.
    private static let minPrefixLength = 3

    // MARK: - State

    private var docsByID: [String: SearchDocEntry] = [:]
    private var tokens: [SearchTokenEntry] = []

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "LocalSearchIndex")

    private let storageURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("search-index.json")
    }()

    private init() {
        load()
    }

    #if DEBUG
    /// Test seam: bypasses the singleton, disk persistence, and `Application Support`.
    init(seedDocs: [SearchDocEntry], seedTokens: [SearchTokenEntry] = []) {
        self.docsByID = Dictionary(uniqueKeysWithValues: seedDocs.map { ($0.documentId, $0) })
        self.tokens = seedTokens
    }
    #endif

    // MARK: - Query

    /// Documents matching every prefix in `text`, where each prefix matches any indexed word
    /// it is a prefix of (so "mod" finds "Modesto.pdf"). Only `type == "file"` documents are
    /// returned — the Drive app has no view for the other `SearchableDocType`s a synced
    /// snapshot might carry (notes, docs, etc. from a web client).
    func query(text: String) -> [SearchDocEntry] {
        let prefixes = SearchIndexTokenizer.normalizeText(text).filter { $0.count >= Self.minPrefixLength }
        guard !prefixes.isEmpty else { return [] }

        var matchingIDs: Set<String>?
        var postingsByPrefix: [String: [SearchTokenEntry]] = [:]
        for prefix in prefixes {
            let matches = tokens.filter { $0.term.hasPrefix(prefix) }
            postingsByPrefix[prefix] = matches
            let ids = Set(matches.map(\.documentId))
            matchingIDs = matchingIDs.map { $0.intersection(ids) } ?? ids
        }
        guard let ids = matchingIDs, !ids.isEmpty else { return [] }

        var scores: [String: Int] = [:]
        for postings in postingsByPrefix.values {
            for entry in postings where ids.contains(entry.documentId) {
                let weight = entry.field == "title" ? Self.titleWeight : 1
                scores[entry.documentId, default: 0] += entry.frequency * weight
            }
        }

        let matchedDocs: [SearchDocEntry] = ids.compactMap { docsByID[$0] }
        let fileDocs: [SearchDocEntry] = matchedDocs.filter { $0.type == "file" }
        let sortedDocs: [SearchDocEntry] = fileDocs.sorted { lhs, rhs in
            let lhsScore = scores[lhs.documentId] ?? 0
            let rhsScore = scores[rhs.documentId] ?? 0
            return lhsScore > rhsScore
        }
        return Array(sortedDocs.prefix(Self.maxResults))
    }

    // MARK: - Indexing a single Drive file (incremental / live)

    /// Adds or updates one file's entry. Returns `true` when the stored entry actually changed
    /// (title, mtime, MIME type, or size), so callers can skip a sync push when nothing moved.
    @discardableResult
    func upsertFile(id: String, title: String, updatedAt: Int64, mimeType: String?, sizeBytes: Int64?) -> Bool {
        guard upsertFileInMemory(id: id, title: title, updatedAt: updatedAt,
                                 mimeType: mimeType, sizeBytes: sizeBytes) else {
            return false
        }
        persist()
        return true
    }

    func removeDocument(id: String) {
        guard docsByID.removeValue(forKey: id) != nil else { return }
        tokens.removeAll { $0.documentId == id }
        persist()
    }

    /// Reconciles the full file set against `entries` — the source of truth from a recursive
    /// drive walk (`DriveService.fetchAllFilesForIndexing`). Adds/updates anything changed,
    /// and — unlike `upsertFile` — removes any `type == "file"` entry not present in `entries`,
    /// so trashed, permanently deleted, or renamed-away files eventually drop out of search.
    /// Returns `true` if the index changed.
    @discardableResult
    func reconcileFileDocuments(
        with entries: [(id: String, title: String, updatedAt: Int64, mimeType: String?, sizeBytes: Int64?)]
    ) -> Bool {
        var changed = false
        let incomingIDs = Set(entries.map(\.id))

        let staleIDs = docsByID.values
            .filter { $0.type == "file" && !incomingIDs.contains($0.documentId) }
            .map(\.documentId)
        for id in staleIDs {
            docsByID.removeValue(forKey: id)
            tokens.removeAll { $0.documentId == id }
            changed = true
        }

        for entry in entries {
            if upsertFileInMemory(id: entry.id, title: entry.title, updatedAt: entry.updatedAt,
                                  mimeType: entry.mimeType, sizeBytes: entry.sizeBytes) {
                changed = true
            }
        }

        if changed {
            logger.debug("reconcileFileDocuments: \(entries.count) seen, \(staleIDs.count) dropped")
            persist()
        }
        return changed
    }

    // MARK: - Snapshot import/export (device sync — see SearchIndexSyncService)

    func exportSnapshot() -> SearchIndexSnapshot {
        SearchIndexSnapshot(
            format: SearchIndexSnapshot.currentFormat,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000),
            docs: Array(docsByID.values),
            tokens: tokens
        )
    }

    /// Replaces the entire local index with `snapshot` — matches the web's `importSnapshot`: a
    /// snapshot is a complete picture, so it is not merged with what is already here. Callers
    /// that need to reassert this device's own files should follow with
    /// `reconcileFileDocuments` afterward.
    func replaceAll(with snapshot: SearchIndexSnapshot) {
        docsByID = Dictionary(uniqueKeysWithValues: snapshot.docs.map { ($0.documentId, $0) })
        tokens = snapshot.tokens
        persist()
        logger.debug("replaceAll: imported \(snapshot.docs.count) documents")
    }

    var documentCount: Int { docsByID.count }

    // MARK: - Private

    @discardableResult
    private func upsertFileInMemory(id: String, title: String, updatedAt: Int64,
                                     mimeType: String?, sizeBytes: Int64?) -> Bool {
        if let existing = docsByID[id],
           existing.title == title, existing.updatedAt == updatedAt,
           existing.mimeType == mimeType, existing.sizeBytes == sizeBytes {
            return false
        }
        index(documentId: id, type: "file", title: title, content: "",
              updatedAt: updatedAt, mimeType: mimeType, sizeBytes: sizeBytes)
        return true
    }

    /// Drive files have no in-app text — `content` is always `""` — mirroring the web
    /// indexer's own treatment of Drive files (`searchIndexer.ts`'s `collectIndexJobs`).
    private func index(documentId: String, type: String, title: String, content: String,
                        updatedAt: Int64, mimeType: String?, sizeBytes: Int64?) {
        tokens.removeAll { $0.documentId == documentId }

        let titleTerms = SearchIndexTokenizer.tokenizeWithPositions(title)
        let contentTerms = SearchIndexTokenizer.tokenizeWithPositions(content)

        tokens.append(contentsOf: titleTerms.map {
            SearchTokenEntry(term: $0.term, documentId: documentId, field: "title",
                             frequency: $0.positions.count, positions: $0.positions)
        })
        tokens.append(contentsOf: contentTerms.map {
            SearchTokenEntry(term: $0.term, documentId: documentId, field: "content",
                             frequency: $0.positions.count, positions: $0.positions)
        })

        docsByID[documentId] = SearchDocEntry(
            documentId: documentId, type: type, title: title,
            titleTerms: titleTerms.map(\.term), contentTerms: contentTerms.map(\.term),
            updatedAt: updatedAt, mimeType: mimeType, sizeBytes: sizeBytes
        )
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        guard let snapshot = try? JSONDecoder().decode(SearchIndexSnapshot.self, from: data) else {
            logger.error("load: failed to decode persisted index, starting empty")
            return
        }
        docsByID = Dictionary(uniqueKeysWithValues: snapshot.docs.map { ($0.documentId, $0) })
        tokens = snapshot.tokens
        logger.debug("load: restored \(self.docsByID.count) documents")
    }

    /// Fire-and-forget disk write, off the main actor so a large index never stalls the UI.
    private func persist() {
        let snapshot = exportSnapshot()
        let url = storageURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            // Unlike Documents, Application Support is not guaranteed to already exist inside
            // the app's container — create it before the first write.
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                      withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
