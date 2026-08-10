import XCTest
import CryptoKit
@testable import NeutrinoDrive

/// The vault is only useful if a key wrapped by the web client opens here, so
/// these tests pin the wire format rather than just the round trip.
final class KeyVaultCryptoTests: XCTestCase {

    // MARK: - Argon2id cross-platform vector

    /// Golden vector shared with the web client.
    ///
    /// Computed independently by hash-wasm's `argon2id` (what
    /// `web/packages/e2e-crypto/src/kdf.ts` calls) for password "hunter2hunter2",
    /// salt = bytes 0…15, t=3, m=65536 KiB, p=1, 32-byte output. If libsodium
    /// and hash-wasm ever diverge, this fails here rather than as an
    /// unexplainable "wrong password" on a user's phone.
    func testArgon2idMatchesWebClientVector() throws {
        let salt = [UInt8](0...15)
        let params = Argon2Params(
            kdf: "argon2id",
            salt: KeyVaultCrypto.encodeBase64URL(salt),
            iterations: 3,
            memoryKiB: 65536,
            parallelism: 1
        )

        let kek = try KeyVaultCrypto.deriveKek(secret: "hunter2hunter2", params: params)

        XCTAssertEqual(
            kek.map { String(format: "%02x", $0) }.joined(),
            "72276abea763e2a12f87e348e3d1811280f9db20b94c75f3d265cc95cb327b36"
        )
    }

    func testDeriveKekIsDeterministic() throws {
        let params = makeParams()
        let a = try KeyVaultCrypto.deriveKek(secret: "correct horse", params: params)
        let b = try KeyVaultCrypto.deriveKek(secret: "correct horse", params: params)

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }

    func testDeriveKekRejectsUnknownKDF() {
        let params = Argon2Params(kdf: "pbkdf2", salt: KeyVaultCrypto.encodeBase64URL([UInt8](0...15)),
                                  iterations: 3, memoryKiB: 65536, parallelism: 1)

        XCTAssertThrowsError(try KeyVaultCrypto.deriveKek(secret: "x", params: params)) { error in
            guard case KeyVaultCryptoError.unsupportedKDF = error else {
                return XCTFail("expected unsupportedKDF, got \(error)")
            }
        }
    }

    /// libsodium is single-lane. Deriving anyway would produce a key that
    /// silently fails to open the blob, so the mismatch must surface here.
    func testDeriveKekRejectsMultiLaneParallelism() {
        let params = Argon2Params(kdf: "argon2id", salt: KeyVaultCrypto.encodeBase64URL([UInt8](0...15)),
                                  iterations: 3, memoryKiB: 65536, parallelism: 4)

        XCTAssertThrowsError(try KeyVaultCrypto.deriveKek(secret: "x", params: params)) { error in
            guard case KeyVaultCryptoError.unsupportedParallelism = error else {
                return XCTFail("expected unsupportedParallelism, got \(error)")
            }
        }
    }

    // MARK: - Secretbox envelope

    func testSealOpenRoundTrip() throws {
        let key = [UInt8](repeating: 7, count: 32)
        let message: [UInt8] = Array("the identity key".utf8)

        let blob = try KeyVaultCrypto.seal(message, key: key)
        XCTAssertEqual(try KeyVaultCrypto.open(blob, key: key), message)
    }

    func testOpenWithWrongKeyReportsDecryptionFailure() throws {
        let blob = try KeyVaultCrypto.seal([1, 2, 3], key: [UInt8](repeating: 7, count: 32))

        XCTAssertThrowsError(try KeyVaultCrypto.open(blob, key: [UInt8](repeating: 8, count: 32))) { error in
            guard case KeyVaultCryptoError.decryptionFailed = error else {
                return XCTFail("expected decryptionFailed, got \(error)")
            }
        }
    }

    func testOpenRejectsTruncatedBlob() {
        // Shorter than a nonce — must not be read as a valid envelope.
        let blob = KeyVaultCrypto.encodeBase64URL([UInt8](repeating: 0, count: 8))

        XCTAssertThrowsError(try KeyVaultCrypto.open(blob, key: [UInt8](repeating: 7, count: 32)))
    }

    // MARK: - Vault

    func testOpenVaultReturnsTheWrappedIdentity() throws {
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let secretKey = [UInt8](identity.rawRepresentation)
        let publicKey = [UInt8](identity.publicKey.rawRepresentation)
        let masterKey = [UInt8](repeating: 3, count: 32)

        let encryptedIdentity = try KeyVaultCrypto.seal(secretKey, key: masterKey)
        let opened = try KeyVaultCrypto.openVault(
            encryptedIdentity: encryptedIdentity,
            publicKeyB64URL: KeyVaultCrypto.encodeBase64URL(publicKey),
            masterKey: masterKey
        )

        XCTAssertEqual(opened.secretKey, secretKey)
        XCTAssertEqual(opened.publicKey, publicKey)
    }

    /// A swapped public key means the vault is not what it claims. Catching it
    /// here turns a class of silent "cannot decrypt this file" bugs into one
    /// clear failure at unlock.
    func testOpenVaultRejectsMismatchedPublicKey() throws {
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let impostor = Curve25519.KeyAgreement.PrivateKey()
        let masterKey = [UInt8](repeating: 3, count: 32)
        let encryptedIdentity = try KeyVaultCrypto.seal([UInt8](identity.rawRepresentation), key: masterKey)

        XCTAssertThrowsError(try KeyVaultCrypto.openVault(
            encryptedIdentity: encryptedIdentity,
            publicKeyB64URL: KeyVaultCrypto.encodeBase64URL([UInt8](impostor.publicKey.rawRepresentation)),
            masterKey: masterKey
        )) { error in
            guard case KeyVaultCryptoError.identityMismatch = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
        }
    }

    func testUnwrapMasterKeyEndToEnd() throws {
        let masterKey = [UInt8](repeating: 42, count: 32)
        let params = makeParams()
        let kek = try KeyVaultCrypto.deriveKek(secret: "s3cret-password", params: params)
        let wrapped = try KeyVaultCrypto.seal(masterKey, key: kek)

        let recovered = try KeyVaultCrypto.unwrapMasterKey(
            encryptedMasterKey: wrapped, secret: "s3cret-password", params: params
        )

        XCTAssertEqual(recovered, masterKey)
    }

    // MARK: - Recovery codes

    /// Must fold exactly as `normalizeRecoveryCode` in the web client, or a code
    /// generated there will not derive the same key here.
    func testRecoveryCodeNormalisationMatchesWebClient() {
        XCTAssertEqual(KeyVaultCrypto.normalizeRecoveryCode("O1IL"), "0111")
        XCTAssertEqual(KeyVaultCrypto.normalizeRecoveryCode("u"), "V")
        XCTAssertEqual(
            KeyVaultCrypto.normalizeRecoveryCode("  4k7m-9pqr 2tvw  "),
            "4K7M9PQR2TVW"
        )
    }

    // MARK: - Base64URL

    func testBase64URLRoundTripAndPaddingTolerance() {
        let bytes: [UInt8] = [251, 255, 190, 0, 1, 2]
        let encoded = KeyVaultCrypto.encodeBase64URL(bytes)

        XCTAssertFalse(encoded.contains("="), "server writes unpadded base64url")
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertEqual(KeyVaultCrypto.decodeBase64URL(encoded), bytes)
        // Standard base64 with padding still decodes — exported key bundles use it.
        XCTAssertEqual(KeyVaultCrypto.decodeBase64URL(Data(bytes).base64EncodedString()), bytes)
    }

    // MARK: - Params decoding

    /// `memoryKiB` must survive decoding verbatim. A snake-case-converting
    /// decoder would look for `memory_ki_b` and fail.
    func testArgon2ParamsDecodeFromServerJSON() throws {
        let json = #"{"kdf":"argon2id","salt":"AAECAwQFBgcICQoLDA0ODw","iterations":3,"memoryKiB":65536,"parallelism":1}"#

        let params = try JSONDecoder().decode(Argon2Params.self, from: Data(json.utf8))

        XCTAssertEqual(params.kdf, "argon2id")
        XCTAssertEqual(params.iterations, 3)
        XCTAssertEqual(params.memoryKiB, 65536)
        XCTAssertEqual(params.parallelism, 1)
    }

    // MARK: - Helpers

    private func makeParams() -> Argon2Params {
        Argon2Params(
            kdf: "argon2id",
            salt: KeyVaultCrypto.encodeBase64URL([UInt8](0...15)),
            iterations: 3,
            memoryKiB: 65536,
            parallelism: 1
        )
    }
}
