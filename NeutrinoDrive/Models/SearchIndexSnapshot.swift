import Foundation

// MARK: - SearchDocEntry

/// One document in the local search index. A Swift-side mirror of the web app's `DocEntry`
/// (`packages/search/src/db.ts` in the `neutrino` repo) — same field names, so a snapshot
/// round-trips between platforms without translation.
///
/// `type` is a free-form string rather than an enum on purpose: the Drive app only ever writes
/// `"file"` entries, but a snapshot pulled from a web client can carry `"note"`, `"document"`,
/// etc. This device has no view for those, and must preserve them byte-for-byte on export
/// rather than fail to decode (or silently drop) a type it doesn't recognise.
struct SearchDocEntry: Codable, Equatable {
    let documentId: String
    var type: String
    var title: String
    var titleTerms: [String]
    var contentTerms: [String]
    /// Epoch millis, matching the web's `Date.now()`-based clock.
    var updatedAt: Int64
    var mimeType: String?
    /// iOS-only addition, absent from the web schema: lets a search result show a file size
    /// without a second round trip. Decodes to `nil` for entries a web client wrote; a web
    /// client ignores the extra JSON key when it reads a snapshot iOS wrote.
    var sizeBytes: Int64?
}

// MARK: - SearchTokenEntry

/// One posting: `term` appears in `documentId`'s `field`, `frequency` times, at `positions`.
/// Mirrors the web's `SnapshotToken` (`packages/search/src/snapshot.ts`) — the JSON-safe form
/// of a posting, with `positions` as a plain array rather than the packed `Uint8Array` the
/// in-memory/IndexedDB form uses.
struct SearchTokenEntry: Codable, Equatable {
    let term: String
    let documentId: String
    /// `"title"` or `"content"` — kept as a string rather than an enum for the same forward-
    /// compatibility reason as `SearchDocEntry.type`.
    let field: String
    let frequency: Int
    let positions: [Int]
}

// MARK: - SearchIndexSnapshot

/// Whole-index snapshot, matching the web's `IndexSnapshot` (`packages/search/src/snapshot.ts`)
/// byte-for-byte in JSON shape. This is what gets JSON-encoded, encrypted, and `PUT` to
/// `/api/v1/search/index` — see `SearchIndexSyncService`.
struct SearchIndexSnapshot: Codable {
    /// Bumped when the snapshot's shape changes. A device reading a snapshot it does not
    /// understand should ignore it and keep its own index rather than import garbage — its
    /// next push replaces the stored snapshot with a current one.
    static let currentFormat = 1

    var format: Int
    /// When the snapshot was taken, epoch millis.
    var createdAt: Int64
    var docs: [SearchDocEntry]
    var tokens: [SearchTokenEntry]
}
