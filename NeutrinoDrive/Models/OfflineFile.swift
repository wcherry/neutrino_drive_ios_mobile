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

    /// Whether smart offline sync put this file here, as opposed to the user pinning it with
    /// "Make Available Offline".
    ///
    /// This is the flag eviction keys on, and the distinction matters more than its size
    /// suggests: an automatic cache that can delete a file the user *explicitly* asked to keep
    /// is not a cache, it is a bug that only shows up on a plane. `SmartOfflineSyncService`
    /// evicts managed entries only, and `SmartOfflineSyncServiceTests` asserts a pinned file
    /// survives a budget overflow that clears everything else.
    ///
    /// Declared last with a default so every existing initializer call site and every manifest
    /// written before this branch still decodes — an older manifest has no `isManaged` key, and
    /// absent means "the user pinned it", which is the safe reading.
    var isManaged: Bool = false

    init(id: String,
         name: String,
         mimeType: String,
         sizeBytes: Int64,
         localURL: URL,
         cachedAt: Date,
         isManaged: Bool = false) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.localURL = localURL
        self.cachedAt = cachedAt
        self.isManaged = isManaged
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(String.self, forKey: .id)
        name      = try c.decode(String.self, forKey: .name)
        mimeType  = try c.decode(String.self, forKey: .mimeType)
        sizeBytes = try c.decode(Int64.self,  forKey: .sizeBytes)
        localURL  = try c.decode(URL.self,    forKey: .localURL)
        cachedAt  = try c.decode(Date.self,   forKey: .cachedAt)
        isManaged = try c.decodeIfPresent(Bool.self, forKey: .isManaged) ?? false
    }
}
