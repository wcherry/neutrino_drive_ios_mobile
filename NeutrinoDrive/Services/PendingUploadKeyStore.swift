import Foundation
import os.log
import NeutrinoCore

// MARK: - PendingUploadKey

/// An upload's sealed DEK, written to disk before its ciphertext is posted and removed once
/// the key is safely on the server.
///
/// ## Why this exists
///
/// `E2EEUploader` commits a file in two network steps on two different sessions: the blob on
/// the **background** session, which is designed to survive suspension and finish in the
/// system's transfer daemon, and the sealed key on the **foreground** one, which is not (a
/// background session cannot run data tasks at all). So the half that survives suspension is
/// the half that uploads ciphertext, and the half that does not is the half that records the
/// key.
///
/// Suspended between the two — routine for the share extension, and exactly what the
/// background session is there to permit — the blob commits, `finalize_upload` writes
/// `encrypted_metadata` so the row declares itself encrypted, and no `file_key_refs` row is
/// ever written. The DEK was generated in memory and nothing persisted it, so the file becomes
/// undecryptable by every client, forever, with no error shown at the time.
///
/// ## Why it is safe at rest
///
/// What is stored is the DEK **already sealed to the user's own Curve25519 public key**
/// (`crypto_box_seal`), which is the same form the server itself holds. Opening it needs the
/// private key in the Keychain. This file adds no exposure the server does not already have.
struct PendingUploadKey: Codable, Equatable {
    /// The logical upload this belongs to — stable across retries, which is what makes a
    /// record findable by the attempt that has to finish it.
    let uploadID: String
    /// The DEK sealed to the user's public key, base64url. Exactly the value the `PUT` sends.
    let sealedFileKey: String
    /// Which identity version the DEK was sealed to. A resumed upload must file the key under
    /// the version it was originally sealed to, not under whatever is active now.
    let keyVersion: Int
    /// For logging and for a human reading the file; nothing branches on it.
    let fileName: String
    /// Set as soon as the blob `POST` returns. Its presence is the signal that the ciphertext
    /// is committed and only the key is missing — the state reconciliation can act on.
    var fileID: String?
    let createdAt: Date
}

// MARK: - PendingUploadKeyStore

/// Persists ``PendingUploadKey`` records as one JSON file in the App Group container.
///
/// **In the App Group, not the app container**, because the share extension is the path most
/// likely to be suspended mid-upload and its process dies the moment the sheet is dismissed.
/// The host app is the one with a launch lifecycle to reconcile from, so it has to be able to
/// see what the extension left behind.
///
/// Not an actor and not `@MainActor`: `E2EEUploader` is deliberately plain, is called from the
/// extension and from background drains, and the whole file is a few hundred bytes. An
/// `NSLock` around read-modify-write of the whole file is both correct and cheaper than
/// threading isolation through the upload path.
final class PendingUploadKeyStore {

    // MARK: - Shared instance

    static let shared = PendingUploadKeyStore()

    /// How long a record with no file id is kept before it is discarded as abandoned.
    ///
    /// Such a record means the blob `POST` never returned, so most likely nothing was
    /// committed and the key protects nothing. It is kept for a month anyway rather than
    /// dropped on the next launch, because the alternative — throwing away the only copy of a
    /// key that *did* protect something — is the failure this whole type exists to prevent.
    static let abandonedRecordTTL: TimeInterval = 30 * 24 * 60 * 60

    // MARK: - Private state

    private let fileURL: URL
    private let lock = NSLock()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "PendingUploadKeyStore")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    /// `fileURL` defaults to `pending-upload-keys.json` in the App Group container, falling
    /// back to Application Support where the group is unavailable. Tests inject a scratch
    /// location.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStorage.appGroupIdentifier
        )
        let directory = group
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = directory.appendingPathComponent("pending-upload-keys.json")
    }

    // MARK: - Reads

    func key(forUploadID uploadID: String) -> PendingUploadKey? {
        lock.lock(); defer { lock.unlock() }
        return load()[uploadID]
    }

    /// Every record, oldest first — the order reconciliation retries them in.
    func all() -> [PendingUploadKey] {
        lock.lock(); defer { lock.unlock() }
        return load().values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Writes

    /// Files `key` under its upload id, replacing any earlier record for the same upload.
    func record(_ key: PendingUploadKey) {
        mutate { $0[key.uploadID] = key }
    }

    /// Marks the blob as committed. Called the moment the upload `POST` returns an id, so the
    /// window in which a record exists but cannot be acted on is as short as the decode.
    func attachFileID(_ fileID: String, toUploadID uploadID: String) {
        mutate { records in
            guard var existing = records[uploadID] else { return }
            existing.fileID = fileID
            records[uploadID] = existing
        }
    }

    func remove(uploadID: String) {
        mutate { $0.removeValue(forKey: uploadID) }
    }

    /// Drops records with no file id that are older than `ttl`. Returns how many went.
    ///
    /// Records that *do* carry a file id are never pruned: one of those is the only thing
    /// standing between a committed blob and a permanently unreadable file, and it stays until
    /// its key is stored or the server says the file is gone.
    @discardableResult
    func pruneAbandoned(olderThan ttl: TimeInterval = abandonedRecordTTL,
                        now: Date = Date()) -> Int {
        var pruned = 0
        mutate { records in
            for (uploadID, record) in records
            where record.fileID == nil && now.timeIntervalSince(record.createdAt) > ttl {
                records.removeValue(forKey: uploadID)
                pruned += 1
            }
        }
        if pruned > 0 {
            logger.debug("pruned \(pruned) abandoned pending upload key(s)")
        }
        return pruned
    }

    // MARK: - Persistence

    private func mutate(_ body: (inout [String: PendingUploadKey]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var records = load()
        body(&records)
        save(records)
    }

    /// Call under `lock`.
    private func load() -> [String: PendingUploadKey] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? Self.decoder.decode([String: PendingUploadKey].self, from: data)) ?? [:]
    }

    /// Call under `lock`.
    private func save(_ records: [String: PendingUploadKey]) {
        do {
            if records.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try Self.encoder.encode(records)
            // `.completeUntilFirstUserAuthentication` matches the accessibility Drive's
            // Keychain items already use: a background transfer has to be able to read this
            // on a locked device, and anything stricter would make the record unreadable
            // exactly when it is needed.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Deliberately loud. A failure here is the difference between a recoverable
            // upload and a file nobody can ever open again.
            logger.error("could not persist pending upload keys: \(error, privacy: .public)")
        }
    }
}
