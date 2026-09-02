import Foundation
import CryptoKit
import NeutrinoCrypto

// MARK: - RecoveryKit
//
// The keyring on paper — and, with nothing stored server-side any more, the only
// copy that survives losing every device.
//
// It carries the *whole* keyring, not just the current key: a file sealed to
// version 1 needs version 1, and a kit that restored only the newest key would
// come back to a library it cannot open. That maps onto how this app already
// stores keys — the active one in `KeyImportService`'s three Keychain items, the
// retired ones in `KeyArchive` — so `install` splits the kit along that seam.
//
// The encoding must match `web/packages/e2e-crypto/src/recoveryKit.ts` exactly,
// since a kit printed on the web is typed in here. It is a compact binary frame
// in Crockford base32 rather than serialised JSON — a three-version keyring is
// 108 bytes this way against roughly 400 as JSON, and that difference is what
// someone has to copy by hand without a transcription error.
//
//   byte 0      magic 'N' (0x4E)
//   byte 1      format version (1)
//   byte 2      entry count
//   per entry   version (2 bytes, big-endian) | secret key (32) | flags (1)
//               flags bit 0 = retired
//
// Timestamps are deliberately absent. They are display metadata, not key
// material, and spending a third of the printed length on them would be paying
// paper for something nobody needs to recover a file.
//
// Only the secret key travels. The public half is derived here rather than read
// off the kit, which is both what keeps the frame short and what makes a
// mistyped character fail as a damaged kit instead of installing a mismatched
// pair that silently opens nothing.

enum RecoveryKitError: LocalizedError {
    case notAKit
    case unsupportedVersion(Int)
    case incomplete
    case damaged
    case unexpectedCharacter(Character)
    case couldNotStore

    var errorDescription: String? {
        switch self {
        case .couldNotStore:
            return "Could not save the restored keys to this device."
        case .notAKit:
            return "This does not look like a Neutrino recovery kit."
        case .unsupportedVersion(let v):
            return "This recovery kit uses format version \(v), which this app does not understand."
        case .incomplete:
            return "This recovery kit is incomplete — some characters are missing."
        case .damaged:
            return "This recovery kit is damaged — it does not name exactly one current key."
        case .unexpectedCharacter(let c):
            return "This recovery kit contains an unexpected character: \(c)"
        }
    }
}

/// What a kit yields: every identity version it carries, and which of them is current.
struct RecoveryKitContents: Equatable {
    /// The version new work is sealed to.
    let activeVersion: Int
    /// Every version in the kit, ascending. Includes the active one.
    let keys: [StoredKeyPair]

    var active: StoredKeyPair? { keys.first { $0.version == activeVersion } }
    var retired: [StoredKeyPair] { keys.filter { $0.version != activeVersion } }
}

enum RecoveryKit {

    /// Crockford base32 — no I, L, O or U.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static let magic: UInt8 = 0x4E   // 'N'
    private static let formatVersion: UInt8 = 1
    private static let secretKeyBytes = 32
    private static let entryBytes = 2 + 32 + 1
    private static let flagRetired: UInt8 = 0x01

    // MARK: - Normalisation

    /// Fold the common misreadings back before decoding.
    ///
    /// Crockford's whole point is that these characters are unambiguous *if* you map them:
    /// someone copying off paper writes O for 0 and l for 1 regardless of what the alphabet says.
    static func normalize(_ text: String) -> String {
        var s = text.uppercased()
        s = s.filter { !$0.isWhitespace && $0 != "-" }
        s = s.replacingOccurrences(of: "O", with: "0")
        s = s.replacingOccurrences(of: "I", with: "1")
        s = s.replacingOccurrences(of: "L", with: "1")
        s = s.replacingOccurrences(of: "U", with: "V")
        return s
    }

    /// True if `text` could plausibly be a kit, for deciding which import path to take.
    static func looksLikeKit(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard normalized.count >= 60 else { return false }
        return normalized.allSatisfy { alphabet.contains($0) }
    }

    // MARK: - base32

    private static func decodeBase32(_ text: String) throws -> [UInt8] {
        var bits = 0
        var value = 0
        var out: [UInt8] = []
        for char in text {
            guard let index = alphabet.firstIndex(of: char) else {
                throw RecoveryKitError.unexpectedCharacter(char)
            }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }

    // MARK: - Import

    /// Rebuild a keyring from a printed kit.
    static func importKit(_ text: String) throws -> RecoveryKitContents {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { throw RecoveryKitError.notAKit }

        let bytes = try decodeBase32(normalized)
        guard bytes.count >= 3, bytes[0] == magic else { throw RecoveryKitError.notAKit }
        guard bytes[1] == formatVersion else {
            throw RecoveryKitError.unsupportedVersion(Int(bytes[1]))
        }

        let count = Int(bytes[2])
        // A truncated kit is the likely outcome of copying by hand, so say that rather than
        // letting a short read produce a subtly wrong key.
        guard bytes.count >= 3 + count * entryBytes else { throw RecoveryKitError.incomplete }

        var keys: [StoredKeyPair] = []
        var activeVersions: [Int] = []
        var offset = 3
        for _ in 0..<count {
            let version = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            let secretKey = Array(bytes[(offset + 2)..<(offset + 2 + secretKeyBytes)])
            let retired = (bytes[offset + 2 + secretKeyBytes] & flagRetired) != 0

            guard let derived = try? Curve25519.KeyAgreement
                    .PrivateKey(rawRepresentation: Data(secretKey)).publicKey.rawRepresentation,
                  let publicKey = SealedKeyCrypto.encodeBase64URL(Array(derived)),
                  let privateKey = SealedKeyCrypto.encodeBase64URL(secretKey)
            else {
                throw RecoveryKitError.damaged
            }

            keys.append(StoredKeyPair(version: version,
                                      publicKey: publicKey,
                                      privateKey: privateKey))
            if !retired { activeVersions.append(version) }
            offset += entryBytes
        }

        // Exactly one current key, or this device would have to guess which identity new uploads
        // are sealed to — and guessing wrong writes files the account itself cannot open.
        guard activeVersions.count == 1 else { throw RecoveryKitError.damaged }

        return RecoveryKitContents(activeVersion: activeVersions[0],
                                   keys: keys.sorted { $0.version < $1.version })
    }

    // MARK: - Install

    /// Write a kit's keys where the rest of the app reads them from.
    ///
    /// The active entry goes into the three Keychain items every read path already uses; the rest
    /// go to `KeyArchive`, which is where `SealedKeyCrypto.storedKeyPair(forVersion:)` looks when a
    /// file names a version this device has rotated away from.
    @discardableResult
    static func install(_ contents: RecoveryKitContents) -> Bool {
        guard let active = contents.active else { return false }
        KeyImportService.storeKeys(KeyBundle(publicKey: active.publicKey,
                                             privateKey: active.privateKey,
                                             keyVersion: String(active.version)))
        return KeyArchive.store(contents.retired)
    }
}
