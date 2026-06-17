import XCTest
import CryptoKit
import Foundation
import Sodium
@testable import NeutrinoDrive

/// Tests for KeyQRDecryptService.
///
/// These tests are written in the red phase of TDD — they describe the full
/// public contract of KeyQRDecryptService before any implementation exists.
/// Every test is expected to fail to compile (or fail at runtime) until the
/// service is implemented.
///
/// The `makeQRString` helper performs genuine Argon2id key derivation and
/// XChaCha20-Poly1305 encryption using swift-sodium, so the happy-path test
/// exercises a real cryptographic round-trip rather than mocked data.
final class KeyQRDecryptServiceTests: XCTestCase {

    // MARK: - Helpers

    private let sodium = Sodium()

    /// Generates a real P-256 key pair and returns its fields serialised as a
    /// JSON string: `{ "public_key": "<x963-base64>", "private_key":
    /// "<raw-base64>", "key_version": "1" }`.
    private func makeKeyPairJSON() -> String {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey  = privateKey.publicKey
        let pubB64  = publicKey.x963Representation.base64EncodedString()
        let privB64 = privateKey.rawRepresentation.base64EncodedString()
        let dict: [String: String] = [
            "public_key":  pubB64,
            "private_key": privB64,
            "key_version": "1",
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        return String(data: data, encoding: .utf8)!
    }

    /// Encrypts `plaintextJSON` under `pin` using the same protocol that
    /// `KeyQRDecryptService.decrypt` must reverse, and returns the outer QR
    /// JSON string ready to be passed to the service.
    ///
    /// Protocol:
    ///   1. Derive a 32-byte key from `pin` + random 16-byte salt via Argon2id.
    ///   2. Seal `plaintextJSON` (UTF-8 bytes) with XChaCha20-Poly1305 using a
    ///      random 24-byte nonce; the output includes the Poly1305 tag.
    ///   3. Build inner JSON `{ "salt": b64, "nonce": b64, "ct": b64 }`.
    ///   4. Base64-encode the inner JSON string (UTF-8) to form `payload`.
    ///   5. Return `{ "v": 1, "alg": "argon2id+xchacha20", "payload": b64 }`.
    private func makeQRString(plaintextJSON: String, pin: String) -> String {
        let saltBytes  = sodium.randomBytes.buf(length: 16)!
        let nonceBytes = sodium.randomBytes.buf(length: 24)!
        let pinBytes   = Array(pin.utf8)

        guard let keyBytes = sodium.pwHash.hash(
            outputLength: 32,
            passwd: pinBytes,
            salt: saltBytes,
            opsLimit: 2,
            memLimit: 67_108_864,
            alg: .Argon2ID13
        ) else {
            XCTFail("Argon2id key derivation failed in test helper")
            // Return a sentinel that will cause the test to fail cleanly.
            return "{}"
        }

        let messageBytes = Array(plaintextJSON.utf8)
        guard let cipherBytes = sodium.secretBox.seal(
            message: messageBytes,
            secretKey: keyBytes,
            nonce: nonceBytes
        ) else {
            XCTFail("XChaCha20-Poly1305 encryption failed in test helper")
            return "{}"
        }

        let saltB64   = Data(saltBytes).base64EncodedString()
        let nonceB64  = Data(nonceBytes).base64EncodedString()
        let ctB64     = Data(cipherBytes).base64EncodedString()

        let innerDict: [String: String] = [
            "salt":  saltB64,
            "nonce": nonceB64,
            "ct":    ctB64,
        ]
        let innerData    = try! JSONSerialization.data(withJSONObject: innerDict, options: .sortedKeys)
        let innerJSONB64 = innerData.base64EncodedString()

        let outerDict: [String: Any] = [
            "v":       1,
            "alg":    "argon2id+xchacha20",
            "payload": innerJSONB64,
        ]
        let outerData = try! JSONSerialization.data(withJSONObject: outerDict)
        return String(data: outerData, encoding: .utf8)!
    }

    // MARK: - Happy Path

    /// A valid QR string encrypted with the correct PIN must return Data that
    /// deserialises to a JSON object containing `public_key`, `private_key`,
    /// and `key_version` — matching the plaintext that was originally encrypted.
    ///
    /// This test performs a genuine Argon2id + XChaCha20-Poly1305 round-trip.
    func test_decrypt_withValidQRAndCorrectPIN_returnsKeyPairData() throws {
        let plaintextJSON = makeKeyPairJSON()
        let qrString      = makeQRString(plaintextJSON: plaintextJSON, pin: "test-pin-1234")

        let resultData = try KeyQRDecryptService.decrypt(qrString: qrString, pin: "test-pin-1234")

        guard let parsed = try JSONSerialization.jsonObject(with: resultData) as? [String: String] else {
            XCTFail("Decrypted data did not parse as [String: String] JSON object")
            return
        }
        XCTAssertNotNil(parsed["public_key"],  "public_key must be present in decrypted JSON")
        XCTAssertNotNil(parsed["private_key"], "private_key must be present in decrypted JSON")
        XCTAssertNotNil(parsed["key_version"], "key_version must be present in decrypted JSON")

        // Verify the round-trip is byte-for-byte identical to the original.
        XCTAssertEqual(resultData, Data(plaintextJSON.utf8))
    }

    // MARK: - Wrong PIN

    /// Passing a PIN that differs from the one used to encrypt must cause
    /// decryption to fail with `KeyQRDecryptError.decryptionFailure`. Argon2id
    /// will derive a different key, so the Poly1305 tag will not verify.
    func test_decrypt_withWrongPIN_throwsDecryptionFailure() {
        let qrString = makeQRString(plaintextJSON: makeKeyPairJSON(), pin: "correct-pin")

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "wrong-pin")
        ) { error in
            guard case KeyQRDecryptError.decryptionFailure = error else {
                return XCTFail("Expected KeyQRDecryptError.decryptionFailure, got \(error)")
            }
        }
    }

    // MARK: - Malformed Payload

    /// When the `payload` field in the outer QR JSON is not valid Base64,
    /// the service must throw `KeyQRDecryptError.base64DecodeFailure` before
    /// attempting any cryptographic operation.
    func test_decrypt_withInvalidBase64Payload_throwsBase64DecodeFailure() {
        // The three consecutive `!` characters are not valid Base64 alphabet.
        let outerDict: [String: Any] = [
            "v":       1,
            "alg":    "argon2id+xchacha20",
            "payload": "not-valid-base64!!!",
        ]
        let qrString = String(
            data: try! JSONSerialization.data(withJSONObject: outerDict),
            encoding: .utf8
        )!

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.base64DecodeFailure = error else {
                return XCTFail("Expected KeyQRDecryptError.base64DecodeFailure, got \(error)")
            }
        }
    }

    // MARK: - Unsupported Version

    /// A QR JSON where `v` is not `1` must throw
    /// `KeyQRDecryptError.unsupportedVersion` immediately, before any attempt
    /// to parse the payload or derive a key.
    func test_decrypt_withUnsupportedVersion_throwsUnsupportedVersion() {
        let outerDict: [String: Any] = [
            "v":       99,
            "alg":    "argon2id+xchacha20",
            "payload": "dGVzdA==",  // valid base64 but irrelevant
        ]
        let qrString = String(
            data: try! JSONSerialization.data(withJSONObject: outerDict),
            encoding: .utf8
        )!

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.unsupportedVersion = error else {
                return XCTFail("Expected KeyQRDecryptError.unsupportedVersion, got \(error)")
            }
        }
    }

    // MARK: - Unsupported Algorithm

    /// A QR JSON where `alg` is a value other than `"argon2id+xchacha20"` must
    /// throw `KeyQRDecryptError.unsupportedAlgorithm`, giving callers a clear
    /// signal to upgrade the app rather than silently corrupting data.
    func test_decrypt_withUnsupportedAlgorithm_throwsUnsupportedAlgorithm() {
        let outerDict: [String: Any] = [
            "v":       1,
            "alg":    "aes-gcm",
            "payload": "dGVzdA==",  // valid base64 but irrelevant
        ]
        let qrString = String(
            data: try! JSONSerialization.data(withJSONObject: outerDict),
            encoding: .utf8
        )!

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.unsupportedAlgorithm = error else {
                return XCTFail("Expected KeyQRDecryptError.unsupportedAlgorithm, got \(error)")
            }
        }
    }

    // MARK: - Garbage QR String

    /// A string that is not JSON at all must throw
    /// `KeyQRDecryptError.invalidQRFormat`. This covers the case where a
    /// non-NeutrinoDrive QR code is accidentally scanned.
    func test_decrypt_withGarbageQRString_throwsInvalidQRFormat() {
        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: "not json at all", pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.invalidQRFormat = error else {
                return XCTFail("Expected KeyQRDecryptError.invalidQRFormat, got \(error)")
            }
        }
    }
}
