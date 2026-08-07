import Foundation
import os.log

// MARK: - SearchService

/// Searches My Drive file names against the on-device search index built and kept in sync by
/// `SearchIndexSyncService` — see that type and `agent_docs/search.md` (`neutrino` repo) for
/// why there is no server-side search endpoint to call: the server only ever holds an
/// encrypted snapshot of the index, never plaintext names.
@MainActor
final class SearchService: ObservableObject {

    // MARK: - Published State

    @Published var results: [DriveItem] = []
    @Published var isSearching: Bool = false
    @Published var error: String?

    // MARK: - Logging

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "SearchService")

    private let localIndex: LocalSearchIndex

    init(localIndex: LocalSearchIndex = .shared) {
        self.localIndex = localIndex
    }

    // MARK: - Search

    /// Searches the local index for `query`.
    ///
    /// An empty/whitespace-only query is a local no-op: results are cleared, `isSearching` is
    /// never set true, and `error` is left untouched.
    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }

        logger.debug("search: q=\(trimmed, privacy: .public)")
        isSearching = true
        error = nil

        let matches = localIndex.query(text: trimmed)
        results = matches.map { DriveItem(searchDocEntry: $0) }
        logger.debug("search: \(matches.count) results")

        isSearching = false
    }
}

// MARK: - DriveItem convenience initialiser

private extension DriveItem {
    init(searchDocEntry entry: SearchDocEntry) {
        self.init(
            id: entry.documentId,
            name: entry.title,
            type: .file,
            parentID: nil,
            size: entry.sizeBytes,
            modifiedAt: Date(timeIntervalSince1970: Double(entry.updatedAt) / 1000),
            isTrashed: false,
            isShared: false,
            mimeType: entry.mimeType
        )
    }
}
