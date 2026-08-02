import XCTest
import Sodium
@testable import NeutrinoDrive

/// Tests for the sealed-DEK primitives.
///
/// The headline test here is `test_shareRoundTrip_recipientCanDecryptTheFile`. The single most
/// important correctness property of the sharing feature is "the recipient can actually decrypt
/// the shared file", and it genuinely cannot be proven end to end without a live server and a
/// second account. What *can* be proven in-process is the whole client-side crypto composition:
/// the encrypt-with-DEK, seal-to-owner, unseal-as-owner, re-seal-to-recipient,
/// unseal-as-recipient, decrypt-with-DEK chain. That is what this file does, using two
/// independently generated keypairs so the recipient's decryption is real rather than the
/// sender's own key under another name.
final class SealedKeyCryptoTests: XCTestCase {

    private let sodium = Sodium()

    // MARK: - Helpers

    private func makeKeyPair() -> (publicKey: String, privateKey: String) {
        let kp = sodium.box.keyPair()!
        return (SealedKeyCrypto.encodeBase64URL(kp.publicKey)!,
                SealedKeyCrypto.encodeBase64URL(kp.secretKey)!)
    }

    /// Encrypts exactly the way `E2EEUploader` does: `[24-byte header][ciphertext]`.
    private func encryptFile(_ plaintext: Data, dek: Bytes) -> Data {
        let xcss = sodium.secretStream.xchacha20poly1305
        let stream = xcss.initPush(secretKey: dek)!
        let header = stream.header()
        let ciphertext = stream.push(message: Array(plaintext), tag: .FINAL)!
        return Data(header + ciphertext)
    }

    /// Decrypts exactly the way `DownloadService` does.
    private func decryptFile(_ encrypted: Data, dek: Bytes) -> Data? {
        let headerSize = 24
        guard encrypted.count > headerSize else { return nil }
        let header = Array(encrypted.prefix(headerSize))
        let ciphertext = Array(encrypted.dropFirst(headerSize))
        let xcss = sodium.secretStream.xchacha20poly1305
        guard let pull = xcss.initPull(secretKey: dek, header: header),
              let (plaintext, _) = pull.pull(cipherText: ciphertext) else { return nil }
        return Data(plaintext)
    }

    // MARK: - The share round trip

    /// The full client-side chain, end to end, with two real keypairs.
    func test_shareRoundTrip_recipientCanDecryptTheFile() throws {
        let sender = makeKeyPair()
        let recipient = makeKeyPair()
        let plaintext = Data("The quick brown fox jumps over the lazy dog.".utf8)

        // 1. Upload: generate a DEK, encrypt the file, seal the DEK to the sender's own key.
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let encryptedFile = encryptFile(plaintext, dek: dek)
        let sealedForSender = try XCTUnwrap(
            SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: sender.publicKey)
        )

        // 2. Share: the sender unseals their own copy of the DEK...
        let recoveredDEK = try XCTUnwrap(
            SealedKeyCrypto.openDEK(sealedBase64URL: sealedForSender,
                                    publicKeyBase64URL: sender.publicKey,
                                    privateKeyBase64URL: sender.privateKey)
        )
        XCTAssertEqual(recoveredDEK, dek, "The sender must recover the exact DEK it sealed.")

        // ...and re-seals it to the recipient's public key.
        let sealedForRecipient = try XCTUnwrap(
            SealedKeyCrypto.seal(dek: recoveredDEK, toPublicKeyBase64URL: recipient.publicKey)
        )

        // 3. Recipient: unseal with their own private key.
        let recipientDEK = try XCTUnwrap(
            SealedKeyCrypto.openDEK(sealedBase64URL: sealedForRecipient,
                                    publicKeyBase64URL: recipient.publicKey,
                                    privateKeyBase64URL: recipient.privateKey),
            "The recipient must be able to unseal the re-wrapped DEK."
        )

        // 4. Recipient decrypts the file the sender uploaded.
        let decrypted = try XCTUnwrap(decryptFile(encryptedFile, dek: recipientDEK),
                                      "The recipient must be able to decrypt the ciphertext.")
        XCTAssertEqual(decrypted, plaintext)
    }

    /// The sender must NOT be able to open the recipient's copy with only their own key —
    /// otherwise the "re-wrap" could be a no-op that happened to work in the test above.
    func test_keySealedToRecipient_doesNotOpenWithSenderKeys() throws {
        let sender = makeKeyPair()
        let recipient = makeKeyPair()
        let dek = sodium.secretStream.xchacha20poly1305.key()

        let sealedForRecipient = try XCTUnwrap(
            SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: recipient.publicKey)
        )

        XCTAssertNil(
            SealedKeyCrypto.openDEK(sealedBase64URL: sealedForRecipient,
                                    publicKeyBase64URL: sender.publicKey,
                                    privateKeyBase64URL: sender.privateKey),
            "A key sealed to the recipient must not open with the sender's keypair."
        )
    }

    /// Guards the specific failure the plan calls out: a wrong wrap that silently produces a
    /// file the recipient cannot decrypt.
    func test_dekSealedToWrongKey_doesNotOpenForIntendedRecipient() throws {
        let recipient = makeKeyPair()
        let bystander = makeKeyPair()
        let dek = sodium.secretStream.xchacha20poly1305.key()

        let sealedToWrongParty = try XCTUnwrap(
            SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: bystander.publicKey)
        )

        XCTAssertNil(
            SealedKeyCrypto.openDEK(sealedBase64URL: sealedToWrongParty,
                                    publicKeyBase64URL: recipient.publicKey,
                                    privateKeyBase64URL: recipient.privateKey)
        )
    }

    // MARK: - Malformed input

    func test_seal_returnsNil_forMalformedPublicKey() {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        XCTAssertNil(SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: "not base64!!!"))
    }

    /// A 32-byte key is the only valid length; sealing to a truncated one would produce
    /// ciphertext nobody could open, so it must be refused rather than attempted.
    func test_seal_returnsNil_forWrongLengthPublicKey() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let shortKey = try XCTUnwrap(SealedKeyCrypto.encodeBase64URL(Array(repeating: 7, count: 16)))
        XCTAssertNil(SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: shortKey))
    }

    func test_openDEK_returnsNil_forMalformedSealedKey() {
        let keys = makeKeyPair()
        XCTAssertNil(SealedKeyCrypto.openDEK(sealedBase64URL: "%%%not-base64%%%",
                                             publicKeyBase64URL: keys.publicKey,
                                             privateKeyBase64URL: keys.privateKey))
    }

    // MARK: - Encoding

    func test_encodeBase64URL_producesUnpaddedOutput() throws {
        // 10 bytes → 16 base64 chars including padding; unpadded must drop the "=".
        let encoded = try XCTUnwrap(SealedKeyCrypto.encodeBase64URL(Array(repeating: 1, count: 10)))
        XCTAssertFalse(encoded.contains("="), "Backend stores unpadded base64url.")
    }

    func test_encodeBase64URL_usesURLSafeAlphabet() throws {
        // Bytes chosen to force '+' and '/' in the standard alphabet.
        let bytes: Bytes = [0xFB, 0xFF, 0xBF, 0xFE, 0xFF, 0xBE]
        let encoded = try XCTUnwrap(SealedKeyCrypto.encodeBase64URL(bytes))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
    }

    func test_decodeBase64URL_roundTripsEncodedBytes() throws {
        let original: Bytes = (0..<64).map { UInt8($0) }
        let encoded = try XCTUnwrap(SealedKeyCrypto.encodeBase64URL(original))
        XCTAssertEqual(SealedKeyCrypto.decodeBase64URL(encoded), original)
    }

    /// The backend emits unpadded, but a padded value from any other source must still decode.
    func test_decodeBase64URL_acceptsPaddedInput() throws {
        let original: Bytes = Array(repeating: 9, count: 10)
        let unpadded = try XCTUnwrap(SealedKeyCrypto.encodeBase64URL(original))
        let padded = unpadded + String(repeating: "=", count: (4 - unpadded.count % 4) % 4)
        XCTAssertEqual(SealedKeyCrypto.decodeBase64URL(padded), original)
    }

    /// The wrap must be interoperable with the web client, which base64url-encodes a
    /// `crypto_box_seal`. A key produced here has to be openable by the standard primitive.
    func test_sealedOutput_isPlainCryptoBoxSeal() throws {
        let kp = sodium.box.keyPair()!
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let sealed = try XCTUnwrap(
            SealedKeyCrypto.seal(dek: dek,
                                 toPublicKeyBase64URL: SealedKeyCrypto.encodeBase64URL(kp.publicKey)!)
        )
        let raw = try XCTUnwrap(SealedKeyCrypto.decodeBase64URL(sealed))
        let opened = sodium.box.open(anonymousCipherText: raw,
                                     recipientPublicKey: kp.publicKey,
                                     recipientSecretKey: kp.secretKey)
        XCTAssertEqual(opened, dek, "Output must be a bare crypto_box_seal, as the web client expects.")
    }
}
