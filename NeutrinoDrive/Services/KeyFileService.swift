import Foundation
import CryptoKit
import Sodium
import os

// MARK: - KeyFileService
//
// The account's **retired** identity keys, fetched from the server and stored in
// `KeyArchive`.
//
// A device enrols by importing one keypair — scanned from the web app's key code
// or read out of an exported key file — and that keypair is the account's
// *active* one. So a device joining an account that has rotated could read
// everything written since the last rotation and nothing written before it. The
// files were still listed, still downloaded, and still would not open. This
// closes that gap, and it is why the pull belongs at enrolment rather than
// somewhere a user has to find.
//
// ── What the server holds, and why it can hold it ────────────────────────────
// Each retired secret key is sealed with `crypto_box_seal` to the keyring's
// **active** public key before upload. The holder of the current identity can
// therefore recover every identity that came before it, and nobody else can —
// the server included, which has no secret half of anything. What is transmitted
// is ciphertext under a key the server does not have, so this does not bend the
// rule that no usable key material reaches it.
//
// The active key is deliberately *not* in the file, which is why losing every
// device and the recovery kit is still terminal. See
// `agent_docs/client-only-key-architecture.md` in the backend repository.
//
// The web side is `web/packages/e2e-crypto/src/keyFile.ts` (`buildKeyFile` /
// `openKeyFile`); the endpoint is `src/drive/key_files/api.rs`.

// MARK: - Wire types
//
// camelCase on the wire. Decoded with a plain JSONDecoder — the app's shared
// snake-case-converting one would rewrite `keyVersion` and the parse would fail.

struct ArchivedKeyDTO: Codable {
    /// The `user_public_keys.version` this entry unwraps to.
    let keyVersion: Int
    /// base64url sealed box over the retired secret key.
    let encryptedKey: String
    /// base64url public half, so an entry can be matched before it is unsealed.
    let publicKey: String?
}

struct KeyFileResponseDTO: Codable {
    let userId: String
    /// Ascending by `keyVersion`.
    let keys: [ArchivedKeyDTO]
    let createdAt: String
    let updatedAt: String
}

// MARK: - Outcome

/// What a pull actually did.
///
/// Reported rather than swallowed: "your older files still will not open" is
/// something the user has to be told, and the difference between "there was
/// nothing to fetch" and "there was, and none of it opened" is the difference
/// between a healthy account and the wrong key.
struct KeyFileRestoreOutcome: Equatable {
    /// Versions added to this device by this pull.
    var recovered: Int = 0
    /// Versions the file carried that this device already had.
    var alreadyHeld: Int = 0
    /// Versions the file carried that would not open. With the account's real
    /// active key this is zero, so a non-zero count means an entry is damaged or
    /// was sealed to something other than what this device holds.
    var unopenable: Int = 0

    /// True when this device's *active* key turns up in the file.
    ///
    /// The file holds retired keys only, so a version in it that this device
    /// believes is current means the account has rotated since this key was
    /// issued — and the newest version is not in the file either, because only
    /// retired ones are. Such a device cannot read anything written since the
    /// rotation and cannot fix that from here; it needs a fresh key.
    ///
    /// This is the one reliable staleness signal the file yields on its own,
    /// which is why it is computed here rather than in a second round trip
    /// against the published public keys.
    var activeIsStale: Bool = false

    /// True when the server answered 404: this account has no key file at all.
    ///
    /// Distinct from an empty result, and the distinction is the whole point.
    /// For an account that has never rotated it is unremarkable. For one whose
    /// active version is 2 or higher it means the retired keys were never backed
    /// up from the device that rotated — so they exist in exactly one browser
    /// profile, no phone can ever open the files sealed to them, and no amount
    /// of re-scanning here will change that. Only that browser can fix it.
    var serverHasNoKeyFile: Bool = false

    /// True when nothing was recovered, held, or refused.
    var isEmpty: Bool { recovered == 0 && alreadyHeld == 0 && unopenable == 0 }
}

// MARK: - Errors

enum KeyFileError: LocalizedError {
    case notAuthenticated
    case noEncryptionKey
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)
    case couldNotStore

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You are signed out. Sign in and try again."
        case .noEncryptionKey:
            return "This device has no encryption key yet, so there is nothing to unlock your "
                 + "older keys with."
        case .serverError(let code):
            return "The server returned an error (\(code))."
        case .decodingError:
            return "The server sent a key file this version of the app does not understand."
        case .couldNotStore:
            return "Could not save the recovered keys to this device."
        }
    }
}

// MARK: - KeyFileService

@MainActor
final class KeyFileService {

    static let shared = KeyFileService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "KeyFileService")

    private static let sodium = Sodium()
    private static let decoder = JSONDecoder()

    /// A Curve25519 secret key is 32 bytes. Anything else came back damaged, and
    /// storing it would produce a key that silently opens nothing.
    private static let curve25519SecretKeyBytes = 32

    /// Set once at app launch, as the other services are, so a caller that does
    /// not hold an `AuthService` can still refresh an expiring token.
    weak var authService: AuthService?

    /// Injected in tests as a `MockURLProtocol`-backed session, exactly as the content services
    /// take one. The pull is the half of this file that talks to the network, and testing only
    /// the unsealing would leave the part that actually reaches the server unproven.
    private let session: URLSession

    private init(session: URLSession = .shared) {
        self.session = session
    }

    /// A service wired to a stubbed session. Tests only — `shared` is what the app uses.
    static func forTesting(session: URLSession) -> KeyFileService {
        KeyFileService(session: session)
    }

    // MARK: - Restore

    /// Fetch the account's key file and store whatever the active key opens.
    ///
    /// Call this straight after a key arrives from anywhere: that is the moment
    /// the device acquires the only key that opens the file. It is safe to call
    /// again — the whole set is rebuilt each time — so a launch-time top-up
    /// costs one request and repairs a device that was offline when its key
    /// arrived, or that enrolled before any of this existed.
    @discardableResult
    func restoreArchivedKeys(authService: AuthService? = nil) async throws -> KeyFileRestoreOutcome {
        guard let active = SealedKeyCrypto.storedKeyPair(),
              let activePublic = SealedKeyCrypto.decodeBase64URL(active.publicKey),
              let activeSecret = SealedKeyCrypto.decodeBase64URL(active.privateKey)
        else {
            throw KeyFileError.noEncryptionKey
        }
        let activeVersion = SealedKeyCrypto.activeKeyVersion()

        guard let response = try await fetch(authService: authService ?? self.authService) else {
            logger.info("restoreArchivedKeys: no key file stored for this account")
            return KeyFileRestoreOutcome(serverHasNoKeyFile: true)
        }

        let existing = KeyArchive.load()
        let held = Set(existing.map(\.version))
        let plan = Self.plan(keys: response.keys,
                             activePublicKey: activePublic,
                             activeSecretKey: activeSecret,
                             activeVersion: activeVersion,
                             held: held)
        let outcome = plan.outcome

        if outcome.unopenable > 0 {
            logger.error("restoreArchivedKeys: \(outcome.unopenable, privacy: .public) entr(ies) did not open with active version \(activeVersion, privacy: .public)")
        }

        // How the archive is written depends on whether the whole file could be read.
        //
        // Fully readable, and it is authoritative: replace, which is also the only way a key
        // retired on the web disappears from this device. Stored even when nothing is new, for
        // exactly that reason.
        //
        // Partly readable, and it is not a complete picture of the account: merge. Replacing on
        // the strength of a file we could only half open would delete keys that arrived by another
        // route — a recovery kit, an earlier pull with a newer identity — to no purpose. That case
        // is a device holding a key the account has rotated away from, which is the moment its
        // older keys matter most.
        let toStore = outcome.unopenable == 0
            ? plan.keys
            : (plan.keys + existing.filter { pair in !plan.keys.contains { $0.version == pair.version } })

        if !toStore.isEmpty || !existing.isEmpty {
            guard KeyArchive.store(toStore) else { throw KeyFileError.couldNotStore }
        }

        logger.info("restoreArchivedKeys: recovered=\(outcome.recovered, privacy: .public) held=\(outcome.alreadyHeld, privacy: .public) unopenable=\(outcome.unopenable, privacy: .public)")
        return outcome
    }

    // MARK: - Unsealing

    /// What a fetched key file yields against a given active keypair.
    ///
    /// The pure half of `restoreArchivedKeys`, split out so the decisions that matter — which
    /// entries open, which are already held, whether the active key is stale — can be tested
    /// against real ciphertext with no network in the way.
    ///
    /// The active version is skipped rather than recovered: it is already in the Keychain, and the
    /// file should not list it at all. That it *does* is what `activeIsStale` reports.
    static func plan(keys: [ArchivedKeyDTO],
                     activePublicKey: Bytes,
                     activeSecretKey: Bytes,
                     activeVersion: Int,
                     held: Set<Int>) -> (outcome: KeyFileRestoreOutcome, keys: [StoredKeyPair]) {
        var outcome = KeyFileRestoreOutcome()
        // Retired keys are the only thing in the file, so our "active" appearing in it means it is
        // not active any more. See `activeIsStale`.
        outcome.activeIsStale = keys.contains { $0.keyVersion >= activeVersion }

        var recovered: [StoredKeyPair] = []
        for key in keys where key.keyVersion != activeVersion {
            if held.contains(key.keyVersion) { outcome.alreadyHeld += 1 }
            guard let pair = open(key, publicKey: activePublicKey, secretKey: activeSecretKey) else {
                // Almost always an entry sealed to a version newer than the one in hand, which
                // reads as a decryption failure but really means "this device's key is not the
                // newest one".
                outcome.unopenable += 1
                continue
            }
            recovered.append(pair)
            if !held.contains(key.keyVersion) { outcome.recovered += 1 }
        }
        return (outcome, recovered)
    }


    /// Open one archived key with the active keypair.
    ///
    /// Everything here came off the network, so none of it is trusted: a secret
    /// key of the wrong length, or a declared public half that is not the
    /// secret's own, is refused rather than stored. Either would surface later
    /// as files that mysteriously will not open, which is a far worse
    /// failure than dropping the entry now.
    static func open(_ key: ArchivedKeyDTO,
                             publicKey: Bytes,
                             secretKey: Bytes) -> StoredKeyPair? {
        guard let sealed = SealedKeyCrypto.decodeBase64URL(key.encryptedKey) else { return nil }
        guard let recovered = sodium.box.open(anonymousCipherText: sealed,
                                              recipientPublicKey: publicKey,
                                              recipientSecretKey: secretKey),
              recovered.count == curve25519SecretKeyBytes,
              // Derived rather than taken from the entry: the declared public
              // half is checked against this, never trusted in its place, so a
              // tampered `publicKey` cannot install a mismatched pair.
              let derived = try? Curve25519.KeyAgreement
                  .PrivateKey(rawRepresentation: Data(recovered)).publicKey.rawRepresentation,
              let derivedBase64 = SealedKeyCrypto.encodeBase64URL(Array(derived)),
              let secretBase64 = SealedKeyCrypto.encodeBase64URL(recovered)
        else { return nil }

        if let declared = key.publicKey, declared != derivedBase64 { return nil }

        return StoredKeyPair(version: key.keyVersion,
                             publicKey: derivedBase64,
                             privateKey: secretBase64)
    }

    // MARK: - HTTP

    /// The caller's key file, or nil when they have never stored one.
    ///
    /// A 404 is a state, not a failure: an account that has never rotated has no
    /// retired keys, and the server refuses to store an empty key file rather
    /// than keeping one around.
    private func fetch(authService: AuthService?) async throws -> KeyFileResponseDTO? {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: SharedStorage.Keys.accessToken) else {
            throw KeyFileError.notAuthenticated
        }
        guard let url = URL(string: SharedStorage.serverHost + "/api/v1/drive/key-file") else {
            throw KeyFileError.serverError(statusCode: 0)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KeyFileError.serverError(statusCode: 0)
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw KeyFileError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(KeyFileResponseDTO.self, from: data)
        } catch {
            logger.error("fetch: decode failed: \(error.localizedDescription, privacy: .public)")
            throw KeyFileError.decodingError(underlying: error)
        }
    }
}
