import Foundation

// MARK: - OfflineFile

/// A file that has been downloaded, decrypted, and persisted to durable local storage so it
/// can be opened later with no network connection.
///
/// `localURL` is stored as an absolute `URL` rather than a directory-relative path. The plan
/// flags path durability across app container relocations (e.g. app updates) as a concern;
/// we accept that latitude here in favor of the simpler representation because
/// `OfflineService` always rewrites the manifest wholesale on every mutation and already has
/// to tolerate a manifest entry whose `localURL` no longer resolves (per the plan's own "known
/// risks" — corrupted/missing files must be skipped, not crash). An absolute URL degrades the
/// same way a stale relative path would in that scenario, so the extra resolution machinery
/// wasn't worth the complexity for this MVP.
struct OfflineFile: Identifiable, Codable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let localURL: URL
    let cachedAt: Date
}
