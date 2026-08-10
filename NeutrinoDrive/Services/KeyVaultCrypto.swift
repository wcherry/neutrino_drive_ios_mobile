import Foundation
import CryptoKit
import Sodium

// MARK: - KeyVaultCrypto
//
// Client half of the key vault: the envelope that lets this device recover the
// Curve25519 identity key from a password or recovery code instead of having
// one pasted in by hand.
//
//   identity secret key  ──secretbox──▶  master key (MK, 32 random bytes)
//   MK                   ──secretbox──▶  one wrapped copy per unlock method
//
// The server stores the wrapped forms and nothing that opens them. See
// `migrations/00105_auth__2026-08-10-000000_create_key_vault` in the backend
// and `web/packages/e2e-crypto/src/vault.ts` for the other implementation.
//
// Wire-compatibility notes — these are the things that silently break
// cross-platform unlock if they drift:
//
//   * Argon2id parameters travel with each blob. libsodium's `crypto_pwhash`
//     takes `memLimit` in BYTES, while the web side (hash-wasm) takes KiB, so
//     the stored `memoryKiB` is multiplied here. Verified identical output for
//     the same inputs across both implementations.
//   * libsodium fixes Argon2 parallelism at 1; the web side sends 1 for the
//     same reason. A blob asking for anything else cannot be derived here and
//     is rejected rather than silently derived wrong.
//   * All binary fields are base64url with no padding.

enum KeyVaultCryptoError: LocalizedError {
    case unsupportedKDF(String)
    case unsupportedParallelism(Int)
    case invalidBase64
    case malformedBlob
    case derivationFailed
    case decryptionFailed
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedKDF(let kdf):
            return "Unsupported key derivation function '\(kdf)'. Update the app and try again."
        case .unsupportedParallelism(let p):
            return "This vault needs Argon2 parallelism \(p), which this device cannot compute."
        case .invalidBase64:
            return "The vault contains malformed data."
        case .malformedBlob:
            return "The vault contains a malformed encrypted value."
        case .derivationFailed:
            return "Could not derive the key from your password on this device."
        case .decryptionFailed:
            return "Wrong password or recovery code."
        case .identityMismatch:
            return "This vault is inconsistent — the unwrapped key does not match its public key."
        }
    }
}

// MARK: - Argon2 parameters

/// Mirrors the `Argon2Params` written by the web client into
/// `user_key_unlocks.params`. Decoded with a plain `JSONDecoder` — a
/// snake-case-converting decoder would mangle `memoryKiB`.
struct Argon2Params: Codable {
    let kdf: String
    /// base64url, 16 bytes.
    let salt: String
    let iterations: Int
    let memoryKiB: Int
    let parallelism: Int
}

// MARK: - KeyVaultCrypto

enum KeyVaultCrypto {

    private static let sodium = Sodium()

    /// 32 bytes — a secretbox key.
    static let masterKeyBytes = 32

    /// Curve25519 keys are 32 bytes in both halves.
    static let curve25519KeyBytes = 32

    // MARK: Key derivation

    /// Derive the 32-byte key-encryption key for a password or recovery code.
    static func deriveKek(secret: String, params: Argon2Params) throws -> [UInt8] {
        guard params.kdf == "argon2id" else {
            throw KeyVaultCryptoError.unsupportedKDF(params.kdf)
        }
        // libsodium's crypto_pwhash is single-lane by construction. Fail loudly
        // rather than deriving a key that would simply never open the blob.
        guard params.parallelism == 1 else {
            throw KeyVaultCryptoError.unsupportedParallelism(params.parallelism)
        }
        guard let salt = decodeBase64URL(params.salt) else {
            throw KeyVaultCryptoError.invalidBase64
        }
        guard let kek = sodium.pwHash.hash(
            outputLength: masterKeyBytes,
            passwd: Array(secret.utf8),
            salt: salt,
            opsLimit: params.iterations,
            memLimit: params.memoryKiB * 1024,   // KiB on the wire, bytes here
            alg: .Argon2ID13
        ) else {
            throw KeyVaultCryptoError.derivationFailed
        }
        return kek
    }

    // MARK: Secretbox envelope

    /// Encrypt `plaintext` under `key`, returning base64url(nonce || ciphertext).
    static func seal(_ plaintext: [UInt8], key: [UInt8]) throws -> String {
        guard let sealed: [UInt8] = sodium.secretBox.seal(message: plaintext, secretKey: key) else {
            throw KeyVaultCryptoError.derivationFailed
        }
        // `seal` already returns nonce || ciphertext in that order, which is
        // exactly the layout the web client writes.
        return encodeBase64URL(sealed)
    }

    /// Inverse of `seal`. Throws `.decryptionFailed` for a wrong key — the
    /// overwhelmingly likely cause is a mistyped password.
    static func open(_ blob: String, key: [UInt8]) throws -> [UInt8] {
        guard let raw = decodeBase64URL(blob) else {
            throw KeyVaultCryptoError.invalidBase64
        }
        guard raw.count > sodium.secretBox.NonceBytes else {
            throw KeyVaultCryptoError.malformedBlob
        }
        guard let plaintext = sodium.secretBox.open(nonceAndAuthenticatedCipherText: raw, secretKey: key) else {
            throw KeyVaultCryptoError.decryptionFailed
        }
        return plaintext
    }

    // MARK: Vault

    /// Recover the master key from a password or recovery-code unlock blob.
    static func unwrapMasterKey(encryptedMasterKey: String, secret: String, params: Argon2Params) throws -> [UInt8] {
        let kek = try deriveKek(secret: secret, params: params)
        return try open(encryptedMasterKey, key: kek)
    }

    /// Unwrap the identity key and confirm it matches the vault's public key.
    ///
    /// Without the check a tampered `encryptedIdentity` would yield a key that
    /// decrypts nothing, surfacing much later as unexplained "cannot decrypt"
    /// errors on individual files instead of one clear failure here.
    static func openVault(
        encryptedIdentity: String,
        publicKeyB64URL: String,
        masterKey: [UInt8]
    ) throws -> (publicKey: [UInt8], secretKey: [UInt8]) {
        let secretKey = try open(encryptedIdentity, key: masterKey)
        guard secretKey.count == curve25519KeyBytes else {
            throw KeyVaultCryptoError.identityMismatch
        }
        guard let publicKey = decodeBase64URL(publicKeyB64URL) else {
            throw KeyVaultCryptoError.invalidBase64
        }
        // X25519: the public key is the base point multiplied by the secret.
        guard let derived = derivePublicKey(from: secretKey), derived == publicKey else {
            throw KeyVaultCryptoError.identityMismatch
        }
        return (publicKey, secretKey)
    }

    /// Derive the Curve25519 public key from a secret key.
    ///
    /// swift-sodium exposes no `scalarmult_base` wrapper and the app depends on
    /// the `Sodium` product only, not `Clibsodium`. CryptoKit's X25519 does the
    /// same multiplication and is what `KeyImportService` already uses to check
    /// a pasted keypair.
    static func derivePublicKey(from secretKey: [UInt8]) -> [UInt8]? {
        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(secretKey)) else {
            return nil
        }
        return [UInt8](priv.publicKey.rawRepresentation)
    }

    // MARK: Recovery codes

    /// Canonicalise a typed recovery code exactly as the web client does, so a
    /// code generated there unlocks here.
    ///
    /// Crockford base32 excludes I, L, O and U; fold them onto their lookalikes
    /// so a code transcribed off paper still works.
    static func normalizeRecoveryCode(_ input: String) -> String {
        var s = input.uppercased()
        s = s.filter { !$0.isWhitespace && $0 != "-" }
        s = s.replacingOccurrences(of: "I", with: "1")
        s = s.replacingOccurrences(of: "L", with: "1")
        s = s.replacingOccurrences(of: "O", with: "0")
        s = s.replacingOccurrences(of: "U", with: "V")
        return s
    }

    // MARK: Base64URL

    static func encodeBase64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts base64url and standard base64, padded or not — the server writes
    /// base64url, but exported key bundles use standard base64.
    static func decodeBase64URL(_ s: String) -> [UInt8]? {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = t.count % 4
        if remainder > 0 {
            t += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: t) else { return nil }
        return [UInt8](data)
    }
}
