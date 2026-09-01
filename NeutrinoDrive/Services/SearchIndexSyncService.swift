import Foundation
import Combine
import Sodium
import os.log

// MARK: - SearchIndexSyncService

/// Keeps the on-device search index in sync with `DriveService`'s live state and with the
/// server's encrypted snapshot at `/api/v1/search/index*`.
///
/// Two update paths, matching the tradeoff in `agent_docs/search.md` (`neutrino` repo, backend)
/// between responsiveness and correctness:
/// - **Live diff**: every time `DriveService.allItems` changes, newly-seen or changed files are
///   upserted immediately (`applyLiveDiff`). This is add/update-only — `allItems` only reflects
///   folders this session has browsed into, so anything absent from it might just be unopened,
///   not deleted.
/// - **Full reindex**: a periodic recursive walk of the whole Drive tree
///   (`DriveService.fetchAllFilesForIndexing`) reconciles the index against the complete,
///   authoritative file set, so trashed/deleted/moved-out files eventually drop out of search
///   too — see `LocalSearchIndex.reconcileFileDocuments`.
///
/// Sync with the server mirrors the web app's `useSearchIndexSync` / `searchIndexSnapshot.ts`:
/// pull (skipping a version this device itself wrote), reconcile, push; a 409
/// `SNAPSHOT_VERSION_CONFLICT` triggers one pull-then-retry rather than looping.
///
/// The snapshot's data key ("SIK") is a separate symmetric key from any file's DEK — sealed to
/// the account's own Curve25519 public key via `SealedKeyCrypto`, exactly like a file's DEK is
/// sealed to self on upload, so only this account's keypair can ever unwrap it.
@MainActor
final class SearchIndexSyncService {

    static let shared = SearchIndexSyncService()

    // MARK: - Dependencies

    private weak var driveService: DriveService?
    private weak var authService: AuthService?
    private let localIndex: LocalSearchIndex

    private var subscription: AnyCancellable?

    // MARK: - Config

    /// Matches the web's five-minute sync throttle. Gates the whole pull/reconcile/push pass —
    /// `syncIfDue()` is meant to be called liberally (e.g. every time the Files tab appears),
    /// and most calls should be no-ops.
    private static let minSyncInterval: TimeInterval = 300

    // MARK: - Local sync state (UserDefaults — device-local, not shared with the extension:
    // the share extension never searches, so it has no reason to see this bookkeeping).

    private enum DefaultsKey {
        static let deviceID = "nd.search.device_id"
        static let lastSyncedVersion = "nd.search.last_synced_version"
        static let lastSyncAttempt = "nd.search.last_sync_attempt"
    }

    private let defaults = UserDefaults.standard

    private var deviceID: String {
        if let existing = defaults.string(forKey: DefaultsKey.deviceID) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: DefaultsKey.deviceID)
        return fresh
    }

    private var lastSyncedVersion: Int? {
        get { defaults.object(forKey: DefaultsKey.lastSyncedVersion) as? Int }
        set {
            if let newValue {
                defaults.set(newValue, forKey: DefaultsKey.lastSyncedVersion)
            } else {
                defaults.removeObject(forKey: DefaultsKey.lastSyncedVersion)
            }
        }
    }

    private var isSyncing = false
    private var pendingPush = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "SearchIndexSyncService")

    private var baseURL: String { SharedStorage.serverHost }

    private init(localIndex: LocalSearchIndex = .shared) {
        self.localIndex = localIndex
    }

    // MARK: - Wiring

    /// Idempotent — safe to call from `FileBrowserView.task` on every appearance of the My
    /// Drive section.
    func attach(driveService: DriveService, authService: AuthService) {
        self.authService = authService
        guard self.driveService !== driveService else { return }
        self.driveService = driveService
        subscription = driveService.$allItems
            .sink { [weak self] items in
                self?.applyLiveDiff(items)
            }
    }

    // MARK: - Live diff

    private func applyLiveDiff(_ items: [DriveItem]) {
        var changed = false
        for item in items where item.type == .file {
            if localIndex.upsertFile(id: item.id, title: item.name, updatedAt: millis(item.modifiedAt),
                                     mimeType: item.mimeType, sizeBytes: item.size) {
                changed = true
            }
        }
        if changed { pendingPush = true }
    }

    // MARK: - Entry point

    /// Runs pull → full reindex → push, throttled to once per `minSyncInterval`. Safe to call
    /// often — most calls return immediately.
    func syncIfDue() async {
        guard !isSyncing else { return }
        let now = Date()
        if let last = defaults.object(forKey: DefaultsKey.lastSyncAttempt) as? Date,
           now.timeIntervalSince(last) < Self.minSyncInterval {
            return
        }
        defaults.set(now, forKey: DefaultsKey.lastSyncAttempt)
        await performSync()
    }

    private func performSync(forcePush: Bool = false) async {
        guard SharedStorage.hasStoredKeys(), SharedStorage.accessToken() != nil else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            try await pull()
        } catch {
            logger.error("pull failed: \(error, privacy: .public)")
        }

        await reconcileCurrentFiles()

        guard pendingPush || forcePush else { return }
        await pushRetryingOnce(force: forcePush)
    }

    /// A reconcile pass *deletes* index entries absent from the walk, so it only runs on a
    /// walk that covered the whole tree. A `nil` result (some branch failed — a network blip,
    /// a mid-walk sign-out) is skipped entirely rather than treated as "nothing exists": doing
    /// otherwise would prune valid entries — including ones a pull from another device may have
    /// just imported — because of a transient failure, not a real deletion. Whatever the index
    /// already has (from a prior pull or the live diff) is left untouched until a walk succeeds.
    private func reconcileCurrentFiles() async {
        guard let driveService else { return }
        guard let files = await driveService.fetchAllFilesForIndexing() else {
            logger.error("reconcileCurrentFiles: walk did not complete — skipping reconcile this pass")
            return
        }
        let entries = files.map {
            (id: $0.id, title: $0.name, updatedAt: millis($0.modifiedAt), mimeType: $0.mimeType, sizeBytes: $0.size)
        }
        if localIndex.reconcileFileDocuments(with: entries) {
            pendingPush = true
        }
    }

    /// A 409 means another device published a newer version while this one was building its
    /// push. One pull-reconcile-push retry resolves it in the common case; a second collision
    /// in the same pass is left for the next `syncIfDue()` rather than looped on indefinitely.
    private func pushRetryingOnce(force: Bool) async {
        do {
            try await push(force: force)
            pendingPush = false
        } catch SearchSyncError.versionConflict {
            logger.debug("push: version conflict — pulling and retrying once")
            do {
                try await pull()
                await reconcileCurrentFiles()
                try await push(force: force)
                pendingPush = false
            } catch {
                logger.error("push retry after conflict failed: \(error, privacy: .public)")
            }
        } catch {
            logger.error("push failed: \(error, privacy: .public)")
        }
    }

    private func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - Pull

    private func pull() async throws {
        guard let meta = try await fetchMeta() else { return }
        if meta.deviceId == deviceID {
            lastSyncedVersion = meta.version
            return
        }
        if let last = lastSyncedVersion, last == meta.version { return }

        guard let key = await resolveIndexKey(sealedToSelf: meta.wrappedKey) else {
            logger.error("pull: could not resolve the index key — skipping")
            return
        }
        let ciphertext = try await downloadSnapshot()
        guard let plaintext = SearchSnapshotCrypto.decrypt(ciphertext, key: key) else {
            logger.error("pull: failed to decrypt snapshot")
            return
        }
        let snapshot: SearchIndexSnapshot
        do {
            snapshot = try JSONDecoder().decode(SearchIndexSnapshot.self, from: plaintext)
        } catch {
            logger.error("pull: failed to decode snapshot: \(error, privacy: .public)")
            return
        }
        guard snapshot.format == SearchIndexSnapshot.currentFormat else {
            logger.error("pull: unsupported snapshot format \(snapshot.format)")
            return
        }
        localIndex.replaceAll(with: snapshot)
        lastSyncedVersion = meta.version
        logger.debug("pull: imported \(snapshot.docs.count) documents at version \(meta.version)")
    }

    // MARK: - Push

    private func push(force: Bool) async throws {
        guard let key = await resolveIndexKey(sealedToSelf: nil) else {
            throw SearchSyncError.encryptionFailed
        }
        let snapshot = localIndex.exportSnapshot()
        let plaintext = try JSONEncoder().encode(snapshot)
        guard let ciphertext = SearchSnapshotCrypto.encrypt(plaintext, key: key) else {
            throw SearchSyncError.encryptionFailed
        }
        guard let pubKey = KeychainService.load(forKey: SharedStorage.Keys.publicKey),
              let wrappedKey = SealedKeyCrypto.seal(dek: key, toPublicKeyBase64URL: pubKey) else {
            throw SearchSyncError.encryptionFailed
        }

        let meta = try await uploadSnapshot(ciphertext: ciphertext, expectedVersion: lastSyncedVersion,
                                            force: force, wrappedKey: wrappedKey, deviceId: deviceID)
        lastSyncedVersion = meta.version
        logger.debug("push: stored version \(meta.version)")
    }

    // MARK: - Key management

    /// The symmetric key that encrypts the snapshot ("SIK"). Stored in the Keychain once
    /// established; recovered from the server's sealed `wrappedKey` on a new device; generated
    /// fresh only when neither exists.
    ///
    /// `sealedToSelf` is the `wrappedKey` from a `GET .../meta` response already in hand
    /// (`pull` has one); passing it avoids a redundant meta fetch. `push` has no such value on
    /// hand and passes `nil`, falling back to a fresh meta fetch only if the Keychain is empty.
    private func resolveIndexKey(sealedToSelf: String?) async -> Bytes? {
        if let stored = KeychainService.load(forKey: SharedStorage.Keys.searchIndexKey),
           let bytes = SealedKeyCrypto.decodeBase64URL(stored) {
            return bytes
        }

        let wrappedKey: String?
        if let sealedToSelf {
            wrappedKey = sealedToSelf
        } else {
            wrappedKey = (try? await fetchMeta())?.wrappedKey
        }
        // The snapshot key carries no version of its own, so every version this device holds is
        // tried, newest first. A snapshot sealed before a rotation opens with the retired key —
        // and giving up after the active one would mint a *fresh* index key below, silently
        // orphaning the snapshot every other device is still reading.
        if let wrappedKey, let unsealed = unsealIndexKey(wrappedKey) {
            persistIndexKey(unsealed)
            return unsealed
        }

        // Neither the Keychain nor the server has a key: this is the first index this account
        // has ever built, on any device.
        let fresh = SearchSnapshotCrypto.generateKey()
        persistIndexKey(fresh)
        return fresh
    }

    /// Open the account's wrapped index key with whichever identity version still opens it.
    private func unsealIndexKey(_ wrappedKey: String) -> Bytes? {
        let versions = [SealedKeyCrypto.activeKeyVersion()]
            + KeyArchive.load().map(\.version).sorted(by: >)
        for version in versions {
            if let unsealed = SealedKeyCrypto.openDEKWithStoredKeys(sealedBase64URL: wrappedKey,
                                                                    keyVersion: version) {
                return unsealed
            }
        }
        return nil
    }

    private func persistIndexKey(_ key: Bytes) {
        guard let encoded = SealedKeyCrypto.encodeBase64URL(key) else { return }
        KeychainService.save(encoded, forKey: SharedStorage.Keys.searchIndexKey)
    }

    // MARK: - HTTP

    private struct APISnapshotMeta: Decodable {
        let version: Int
        let sizeBytes: Int64
        let wrappedKey: String
        let deviceId: String?
        let updatedAt: String
    }

    enum SearchSyncError: Error {
        case notAuthenticated
        case encryptionFailed
        case versionConflict
        case serverError(statusCode: Int)
        case networkError(underlying: Error)
    }

    private func authorizedRequest(method: String, url: URL) async throws -> URLRequest {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw SearchSyncError.notAuthenticated
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// `nil` when the account has never uploaded a snapshot (404) — not an error.
    private func fetchMeta() async throws -> APISnapshotMeta? {
        guard let url = URL(string: baseURL + "/api/v1/search/index/meta") else {
            throw SearchSyncError.serverError(statusCode: 0)
        }
        let req = try await authorizedRequest(method: "GET", url: url)
        let (data, response) = try await send(req)
        if response.statusCode == 404 { return nil }
        try Self.throwIfError(response)
        return try JSONDecoder().decode(APISnapshotMeta.self, from: data)
    }

    private func downloadSnapshot() async throws -> Data {
        guard let url = URL(string: baseURL + "/api/v1/search/index") else {
            throw SearchSyncError.serverError(statusCode: 0)
        }
        let req = try await authorizedRequest(method: "GET", url: url)
        let (data, response) = try await send(req)
        try Self.throwIfError(response)
        return data
    }

    private func uploadSnapshot(ciphertext: Data, expectedVersion: Int?, force: Bool,
                                wrappedKey: String, deviceId: String) async throws -> APISnapshotMeta {
        var components = URLComponents(string: baseURL + "/api/v1/search/index")
        var query = [
            URLQueryItem(name: "wrappedKey", value: wrappedKey),
            URLQueryItem(name: "deviceId", value: deviceId),
        ]
        if let expectedVersion { query.append(URLQueryItem(name: "expectedVersion", value: String(expectedVersion))) }
        if force { query.append(URLQueryItem(name: "force", value: "true")) }
        components?.queryItems = query
        guard let url = components?.url else { throw SearchSyncError.serverError(statusCode: 0) }

        var req = try await authorizedRequest(method: "PUT", url: url)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = ciphertext

        let (data, response) = try await send(req)
        if response.statusCode == 409 { throw SearchSyncError.versionConflict }
        try Self.throwIfError(response)
        return try JSONDecoder().decode(APISnapshotMeta.self, from: data)
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        logger.debug("--> \(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            logger.error("network error: \(req.url?.path ?? "?", privacy: .public) \(error, privacy: .public)")
            throw SearchSyncError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SearchSyncError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public)")
        return (data, http)
    }

    private static func throwIfError(_ response: HTTPURLResponse) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        throw SearchSyncError.serverError(statusCode: response.statusCode)
    }
}
