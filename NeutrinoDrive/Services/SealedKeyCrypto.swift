import Foundation
import Sodium

// MARK: - SealedKeyCrypto

/// The sealed-DEK primitives — the one place in the app where a file's data encryption key
/// is wrapped to, or unwrapped from, a Curve25519 public key.
///
/// **Why this type exists.** Before Phase 5 these three lines lived inline inside
/// `E2EEUploader.upload` (seal to self) and `DownloadService.download` (unseal). Sharing needs
/// both halves *and* a seal to somebody else's key. A third inline copy would be the classic
/// silent-divergence bug: a wrong wrap does not fail any build, does not fail any request, and
/// is only discovered when a recipient cannot open a file. Extracting the primitives means
/// upload, download, and share provably run the same code.
///
/// This mirrors the reasoning already recorded in `project.yml` for the share extension —
/// compiling literally the same source is a stronger guarantee than an API contract.
///
/// ## Wire format
///
/// Everything here is libsodium `crypto_box_seal` (Curve25519 + XSalsa20-Poly1305, anonymous
/// sender), base64url **without** padding. That is fixed by the backend, not chosen here:
///
/// - `src/drive/encryption/model.rs` — "the DEK sealed with the user's Curve25519 public key
///   (libsodium `crypto_box_seal`), base64url-encoded".
/// - `src/drive/encryption/api.rs` — `ShareFileKeyRequest.encryptedFileKey` is "DEK sealed to
///   the recipient's Curve25519 public key (base64url)".
/// - `src/auth/dto.rs` — public keys are "Base64url-encoded Curve25519 public key (32 bytes)".
///
/// The web client's `encryptFileKey`/`decryptFileKey` (`packages/e2e-crypto/src/crypto.ts`) are
/// the same two calls, so keys wrapped here open there and vice versa.
enum SealedKeyCrypto {

    private static let sodium = Sodium()

    /// Curve25519 public keys are 32 bytes. A shorter or longer value means the caller was
    /// handed something that is not a key (a truncated string, a JSON error body decoded as
    /// text, a hex-encoded key), and sealing to it would produce ciphertext nobody can open.
    static let publicKeyByteCount = 32

    // MARK: - Seal

    /// Seal `dek` to a recipient's base64url-encoded Curve25519 public key.
    ///
    /// Returns `nil` if the key is not decodable base64url or is not 32 bytes — deliberately
    /// refusing rather than sealing to a malformed key, because the resulting ciphertext would
    /// be silently undecryptable.
    static func seal(dek: Bytes, toPublicKeyBase64URL publicKey: String) -> String? {
        guard let publicKeyBytes = decodeBase64URL(publicKey),
              publicKeyBytes.count == publicKeyByteCount else {
            return nil
        }
        guard let sealed = sodium.box.seal(message: dek, recipientPublicKey: publicKeyBytes) else {
            return nil
        }
        return sodium.utils.bin2base64(sealed, variant: .URLSAFE_NO_PADDING)
    }

    // MARK: - Open

    /// Open a sealed DEK with the holder's own keypair.
    ///
    /// `crypto_box_seal_open` needs both halves of the recipient keypair: the public key is
    /// part of the ephemeral-key derivation, not merely a convenience.
    static func openDEK(sealedBase64URL sealed: String,
                        publicKeyBase64URL publicKey: String,
                        privateKeyBase64URL privateKey: String) -> Bytes? {
        guard let sealedBytes = decodeBase64URL(sealed),
              let publicKeyBytes = decodeBase64URL(publicKey),
              let privateKeyBytes = decodeBase64URL(privateKey) else {
            return nil
        }
        return sodium.box.open(anonymousCipherText: sealedBytes,
                               recipientPublicKey: publicKeyBytes,
                               recipientSecretKey: privateKeyBytes)
    }

    // MARK: - Stored Keypair

    /// The signed-in user's own keypair, as stored by `KeyImportService`.
    ///
    /// Lives here rather than at each call site so "which Keychain entries hold the keypair"
    /// is answered once. Returns `nil` when either half is missing — callers treat that as
    /// `noEncryptionKey`.
    static func storedKeyPair() -> (publicKey: String, privateKey: String)? {
        guard let publicKey = KeychainService.load(forKey: SharedStorage.Keys.publicKey),
              let privateKey = KeychainService.load(forKey: SharedStorage.Keys.privateKey) else {
            return nil
        }
        return (publicKey, privateKey)
    }

    /// Convenience: unseal using the stored keypair.
    static func openDEKWithStoredKeys(sealedBase64URL sealed: String) -> Bytes? {
        guard let keyPair = storedKeyPair() else { return nil }
        return openDEK(sealedBase64URL: sealed,
                       publicKeyBase64URL: keyPair.publicKey,
                       privateKeyBase64URL: keyPair.privateKey)
    }

    // MARK: - Encoding

    /// Decodes base64url, tolerating both padded and unpadded input.
    ///
    /// The backend emits unpadded, but `Data(base64URLEncoded:)` — already used by
    /// `E2EEUploader` for the stored public key — re-pads before decoding. Accepting both
    /// means a padded value from any source still works.
    static func decodeBase64URL(_ string: String) -> Bytes? {
        if let bytes = sodium.utils.base642bin(string, variant: .URLSAFE_NO_PADDING) {
            return bytes
        }
        // Fall back to the padded variant, then to a manual re-pad.
        if let bytes = sodium.utils.base642bin(string, variant: .URLSAFE) {
            return bytes
        }
        guard let data = Data(base64URLEncoded: string) else { return nil }
        return Array(data)
    }

    /// Encodes to unpadded base64url — the form the backend stores.
    static func encodeBase64URL(_ bytes: Bytes) -> String? {
        sodium.utils.bin2base64(bytes, variant: .URLSAFE_NO_PADDING)
    }
}
