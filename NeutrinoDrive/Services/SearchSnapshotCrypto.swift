import Foundation
import Sodium

// MARK: - SearchSnapshotCrypto

/// Symmetric encrypt/decrypt for the search-index snapshot blob.
///
/// Same primitive as file content (`E2EEUploader.upload` / `DownloadService.download`):
/// XChaCha20-Poly1305 via libsodium's secretstream, a single push with the `.FINAL` tag,
/// wire format `[24-byte header][ciphertext]`. Matches the web's `encryptFile`/`decryptFile`
/// (`packages/e2e-crypto/src/crypto.ts`), which is what `encryptSnapshot`/`decryptSnapshot`
/// (`packages/search`'s sync path) also calls — so a snapshot iOS encrypts opens on the web
/// and vice versa.
///
/// Extracted here rather than inlined a third time: the snapshot is the third caller of the
/// exact same few lines, and `SealedKeyCrypto`'s header comment already explains why a fourth
/// inline copy would be the wrong call — a silently wrong wrap/unwrap here would surface only
/// as "sync never finds anything," which is a much harder bug to notice than a failed request.
enum SearchSnapshotCrypto {

    private static let sodium = Sodium()
    private static let headerByteCount = 24

    /// A fresh random key for a brand-new index — libsodium's secretstream key size.
    static func generateKey() -> Bytes {
        sodium.secretStream.xchacha20poly1305.key()
    }

    static func encrypt(_ plaintext: Data, key: Bytes) -> Data? {
        let xcss = sodium.secretStream.xchacha20poly1305
        guard let stream = xcss.initPush(secretKey: key) else { return nil }
        let header = stream.header()
        guard let ciphertext = stream.push(message: Array(plaintext), tag: .FINAL) else { return nil }
        return Data(header + ciphertext)
    }

    /// `nil` on malformed input (too short for a header) or a failed open — wrong key, a
    /// truncated/corrupted blob, or a snapshot sealed by an incompatible client.
    static func decrypt(_ data: Data, key: Bytes) -> Data? {
        guard data.count > headerByteCount else { return nil }
        let header = Array(data.prefix(headerByteCount))
        let ciphertext = Array(data.dropFirst(headerByteCount))
        let xcss = sodium.secretStream.xchacha20poly1305
        guard let stream = xcss.initPull(secretKey: key, header: header) else { return nil }
        guard let (plaintext, _) = stream.pull(cipherText: ciphertext) else { return nil }
        return Data(plaintext)
    }
}
