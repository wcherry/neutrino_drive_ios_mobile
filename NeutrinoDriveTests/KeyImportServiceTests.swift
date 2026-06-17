import XCTest
import CryptoKit
import Foundation
@testable import NeutrinoDrive

/// Tests for KeyImportService.
///
/// These tests are written in the red phase of TDD — they describe the full
/// public contract of KeyImportService before any implementation exists. Every
/// test in this file is expected to fail to compile (or fail at runtime) until
/// the implementation is provided.
///
/// Key generation uses CryptoKit's P256 APIs so the happy-path tests exercise
/// a genuine cryptographic key pair rather than arbitrary strings.
///
/// All tests clean up Keychain state in setUp/tearDown using
/// KeyImportService.removeKeys() so no test can bleed into another.
final class KeyImportServiceTests: XCTestCase {

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        KeyImportService.removeKeys()
    }

    override func tearDown() {
        super.tearDown()
        KeyImportService.removeKeys()
    }

    // MARK: - Helpers

    /// Builds a JSON Data payload from the provided field dictionary.
    /// Pass nil for a key to omit it from the payload entirely.
    private func makeJSON(
        publicKey: String?,
        privateKey: String?,
        keyVersion: String?
    ) -> Data {
        var fields: [String: String] = [:]
        if let pub = publicKey  { fields["public_key"]  = pub }
        if let priv = privateKey { fields["private_key"] = priv }
        if let ver = keyVersion  { fields["key_version"] = ver }
        return try! JSONSerialization.data(withJSONObject: fields)
    }

    /// Generates a fresh P-256 key pair and returns (publicKeyBase64, privateKeyBase64).
    private func makeRealKeyPair() -> (pub: String, priv: String) {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let pubB64  = publicKey.x963Representation.base64EncodedString()
        let privB64 = privateKey.rawRepresentation.base64EncodedString()
        return (pubB64, privB64)
    }

    /// Converts a standard Base64 string to Base64URL encoding
    /// (replaces `+` with `-`, `/` with `_`, and strips `=` padding).
    private func toBase64URL(_ base64: String) -> String {
        base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Happy Path

    /// Valid JSON containing a real matching P-256 key pair must succeed and
    /// return a KeyBundle whose fields exactly match what was supplied.
    func test_importKey_withValidMatchingP256KeyPair_returnsKeyBundle() throws {
        let (pubB64, privB64) = makeRealKeyPair()
        let data = makeJSON(publicKey: pubB64, privateKey: privB64, keyVersion: "1")

        let bundle = try KeyImportService.importKey(from: data)

        XCTAssertEqual(bundle.publicKey,  pubB64)
        XCTAssertEqual(bundle.privateKey, privB64)
        XCTAssertEqual(bundle.keyVersion, "1")
    }

    /// Base64URL-encoded keys (using `-` and `_` instead of `+` and `/`,
    /// without `=` padding) must also be accepted and parsed correctly.
    func test_importKey_withBase64URLEncodedKeys_returnsKeyBundle() throws {
        let (pubB64, privB64) = makeRealKeyPair()
        let pubURL  = toBase64URL(pubB64)
        let privURL = toBase64URL(privB64)
        let data = makeJSON(publicKey: pubURL, privateKey: privURL, keyVersion: "2")

        let bundle = try KeyImportService.importKey(from: data)

        XCTAssertEqual(bundle.publicKey,  pubURL)
        XCTAssertEqual(bundle.privateKey, privURL)
        XCTAssertEqual(bundle.keyVersion, "2")
    }

    // MARK: - Invalid JSON

    /// Bytes that are not parseable JSON must throw KeyImportError.invalidJSON.
    func test_importKey_withMalformedJSON_throwsInvalidJSON() {
        let garbage = Data("this is not json }{".utf8)

        XCTAssertThrowsError(try KeyImportService.importKey(from: garbage)) { error in
            guard case KeyImportError.invalidJSON = error else {
                return XCTFail("Expected KeyImportError.invalidJSON, got \(error)")
            }
        }
    }

    // MARK: - Missing Fields

    /// A JSON payload that lacks the `public_key` field must throw
    /// KeyImportError.missingFields.
    func test_importKey_withMissingPublicKey_throwsMissingFields() {
        let (_, privB64) = makeRealKeyPair()
        let data = makeJSON(publicKey: nil, privateKey: privB64, keyVersion: "1")

        XCTAssertThrowsError(try KeyImportService.importKey(from: data)) { error in
            guard case KeyImportError.missingFields = error else {
                return XCTFail("Expected KeyImportError.missingFields, got \(error)")
            }
        }
    }

    /// A JSON payload that lacks the `private_key` field must throw
    /// KeyImportError.missingFields.
    func test_importKey_withMissingPrivateKey_throwsMissingFields() {
        let (pubB64, _) = makeRealKeyPair()
        let data = makeJSON(publicKey: pubB64, privateKey: nil, keyVersion: "1")

        XCTAssertThrowsError(try KeyImportService.importKey(from: data)) { error in
            guard case KeyImportError.missingFields = error else {
                return XCTFail("Expected KeyImportError.missingFields, got \(error)")
            }
        }
    }

    /// A JSON payload that lacks the `key_version` field must throw
    /// KeyImportError.missingFields.
    func test_importKey_withMissingKeyVersion_throwsMissingFields() {
        let (pubB64, privB64) = makeRealKeyPair()
        let data = makeJSON(publicKey: pubB64, privateKey: privB64, keyVersion: nil)

        XCTAssertThrowsError(try KeyImportService.importKey(from: data)) { error in
            guard case KeyImportError.missingFields = error else {
                return XCTFail("Expected KeyImportError.missingFields, got \(error)")
            }
        }
    }

    // MARK: - Invalid Base64

    /// A JSON payload where `public_key` is not valid Base64 must throw
    /// KeyImportError.invalidBase64. The private key is a real key so that
    /// the error is unambiguously caused by the public key value.
    func test_importKey_withInvalidBase64PublicKey_throwsInvalidBase64() {
        let (_, privB64) = makeRealKeyPair()
        // Three consecutive `=` signs are not valid Base64.
        let data = makeJSON(publicKey: "not-valid-base64-===", privateKey: privB64, keyVersion: "1")

        XCTAssertThrowsError(try KeyImportService.importKey(from: data)) { error in
            guard case KeyImportError.invalidBase64 = error else {
                return XCTFail("Expected KeyImportError.invalidBase64, got \(error)")
            }
        }
    }

    /// A JSON payload where `private_key` is not valid Base64 must throw
    /// KeyImportError.invalidBase64.
    func test_importKey_withInvalidBase64PrivateKey_throwsInvalidBase64() {
        let (pubB64, _) = makeRealKeyPair()
        let data = makeJSON(publicKey: pubB64, privateKey: "not-valid-base64-===", keyVersion: "1")

        XCTAssertThrowsError(try KeyImportService.importKey(from: data)) { error in
            guard case KeyImportError.invalidBase64 = error else {
                return XCTFail("Expected KeyImportError.invalidBase64, got \(error)")
            }
        }
    }

    // MARK: - Mismatched Key Pair

    /// When two separate P-256 keys are generated and their public/private
    /// components are mixed, importKey must detect that the public key does not
    /// correspond to the supplied private key and throw
    /// KeyImportError.keyPairMismatch.
    func test_importKey_withMismatchedKeyPair_throwsKeyPairMismatch() {
        let keyA = P256.Signing.PrivateKey()
        let keyB = P256.Signing.PrivateKey()
        // Public key from A paired with private key from B — not a valid pair.
        let pubB64  = keyA.publicKey.x963Representation.base64EncodedString()
        let privB64 = keyB.rawRepresentation.base64EncodedString()
        let data = makeJSON(publicKey: pubB64, privateKey: privB64, keyVersion: "1")

        XCTAssertThrowsError(try KeyImportService.importKey(from: data)) { error in
            guard case KeyImportError.keyPairMismatch = error else {
                return XCTFail("Expected KeyImportError.keyPairMismatch, got \(error)")
            }
        }
    }

    // MARK: - PEM Format

    /// If `public_key` begins with the PEM header `-----BEGIN`, importKey must
    /// throw KeyImportError.unsupportedFormat instead of attempting to parse it.
    func test_importKey_withPEMPublicKey_throwsUnsupportedFormat() {
        let pemPublicKey = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYFK4EEACIDQgAE\n-----END PUBLIC KEY-----"
        let (_, privB64) = makeRealKeyPair()
        let data = makeJSON(publicKey: pemPublicKey, privateKey: privB64, keyVersion: "1")

        XCTAssertThrowsError(try KeyImportService.importKey(from: data)) { error in
            guard case KeyImportError.unsupportedFormat = error else {
                return XCTFail("Expected KeyImportError.unsupportedFormat, got \(error)")
            }
        }
    }

    /// If `private_key` begins with the PEM header `-----BEGIN`, importKey must
    /// throw KeyImportError.unsupportedFormat.
    func test_importKey_withPEMPrivateKey_throwsUnsupportedFormat() {
        let (pubB64, _) = makeRealKeyPair()
        let pemPrivateKey = "-----BEGIN EC PRIVATE KEY-----\nMHQCAQEEIOaI8lCVMN3XKRJC\n-----END EC PRIVATE KEY-----"
        let data = makeJSON(publicKey: pubB64, privateKey: pemPrivateKey, keyVersion: "1")

        XCTAssertThrowsError(try KeyImportService.importKey(from: data)) { error in
            guard case KeyImportError.unsupportedFormat = error else {
                return XCTFail("Expected KeyImportError.unsupportedFormat, got \(error)")
            }
        }
    }

    // MARK: - hasStoredKeys

    /// After removeKeys() (called in setUp), hasStoredKeys() must return false
    /// because no encryption keys are present in the Keychain.
    func test_hasStoredKeys_withNoKeysInKeychain_returnsFalse() {
        // setUp already called removeKeys(); this verifies the post-condition.
        XCTAssertFalse(KeyImportService.hasStoredKeys())
    }

    /// Manually saving all three key entries via KeychainService causes
    /// hasStoredKeys() to return true.
    func test_hasStoredKeys_afterManualSaveOfAllThreeKeys_returnsTrue() {
        KeychainService.save("fake-public-key",  forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.save("fake-private-key", forKey: KeyImportService.privateKeyKeychainKey)
        KeychainService.save("1",                forKey: KeyImportService.keyVersionKeychainKey)

        XCTAssertTrue(KeyImportService.hasStoredKeys())
    }

    // MARK: - removeKeys

    /// After manually saving all three key entries and calling removeKeys(),
    /// loading each individual Keychain key must return nil.
    func test_removeKeys_afterManualSave_clearsAllThreeKeychainEntries() {
        KeychainService.save("fake-public-key",  forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.save("fake-private-key", forKey: KeyImportService.privateKeyKeychainKey)
        KeychainService.save("1",                forKey: KeyImportService.keyVersionKeychainKey)

        KeyImportService.removeKeys()

        XCTAssertNil(
            KeychainService.load(forKey: KeyImportService.publicKeyKeychainKey),
            "public key Keychain entry must be nil after removeKeys()"
        )
        XCTAssertNil(
            KeychainService.load(forKey: KeyImportService.privateKeyKeychainKey),
            "private key Keychain entry must be nil after removeKeys()"
        )
        XCTAssertNil(
            KeychainService.load(forKey: KeyImportService.keyVersionKeychainKey),
            "key version Keychain entry must be nil after removeKeys()"
        )
    }
}
