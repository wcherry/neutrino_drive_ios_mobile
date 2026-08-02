import XCTest
import CommonCrypto
import CryptoKit
import Foundation
import Sodium
@testable import NeutrinoDrive

/// Tests for KeyQRDecryptService.
///
/// These describe the full public contract of `KeyQRDecryptService.decrypt`, in the wire
/// format the backend's key-export QR actually emits: a flat JSON envelope carrying
/// base64url `salt` / `nonce` / `ct`, keyed by PBKDF2-SHA256 over the PIN and sealed with
/// XSalsa20-Poly1305. An earlier revision of these tests described an `argon2id+xchacha20`
/// envelope with a nested base64 `payload` — that was the pre-implementation TDD sketch,
/// replaced when QR scanning was made to work against the real exporter.
///
/// The `makeQRString` helper performs genuine PBKDF2 key derivation and libsodium
/// secretBox encryption, so the happy-path test exercises a real cryptographic round-trip
/// rather than mocked data.
final class KeyQRDecryptServiceTests: XCTestCase {

    // MARK: - Helpers

    private let sodium = Sodium()

    /// The PBKDF2 work factor used by every test that is not specifically about the default.
    /// Production QRs carry 600 000; deriving that per test would add seconds to the suite for
    /// no extra coverage, and the count is read straight off the envelope's `iter` field.
    private let testIterations = 10_000

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
    /// `KeyQRDecryptService.decrypt` must reverse, and returns the QR JSON string
    /// ready to be passed to the service.
    ///
    /// Protocol:
    ///   1. Derive a 32-byte key from `pin` + a random 16-byte salt via PBKDF2-SHA256.
    ///   2. Seal `plaintextJSON` (UTF-8 bytes) with XSalsa20-Poly1305 (libsodium
    ///      secretBox) using a random 24-byte nonce; the output carries the tag.
    ///   3. Return `{ "v": 1, "alg": "pbkdf2-sha256+xsalsa20",
    ///                "salt": b64url, "nonce": b64url, "ct": b64url, "iter": n }`.
    ///
    /// - Parameter includeIterField: when false, `iter` is omitted so the service has to
    ///   fall back to its documented 600 000 default.
    private func makeQRString(
        plaintextJSON: String,
        pin: String,
        iterations: Int,
        includeIterField: Bool = true
    ) -> String {
        let saltBytes  = sodium.randomBytes.buf(length: 16)!
        let nonceBytes = sodium.randomBytes.buf(length: 24)!

        guard let key = pbkdf2SHA256(pin: pin, salt: Data(saltBytes), iterations: iterations) else {
            XCTFail("PBKDF2 key derivation failed in test helper")
            // Return a sentinel that will cause the test to fail cleanly.
            return "{}"
        }

        guard let cipherBytes = sodium.secretBox.seal(
            message: Array(plaintextJSON.utf8),
            secretKey: Array(key),
            nonce: nonceBytes
        ) else {
            XCTFail("XSalsa20-Poly1305 encryption failed in test helper")
            return "{}"
        }

        var outerDict: [String: Any] = [
            "v":     1,
            "alg":   "pbkdf2-sha256+xsalsa20",
            "salt":  base64URL(Data(saltBytes)),
            "nonce": base64URL(Data(nonceBytes)),
            "ct":    base64URL(Data(cipherBytes)),
        ]
        if includeIterField { outerDict["iter"] = iterations }

        let outerData = try! JSONSerialization.data(withJSONObject: outerDict)
        return String(data: outerData, encoding: .utf8)!
    }

    /// Base64url, unpadded — the encoding the exporter emits.
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func pbkdf2SHA256(pin: String, salt: Data, iterations: Int) -> Data? {
        let pinData = Data(pin.utf8)
        var derivedKey = Data(repeating: 0, count: 32)

        let status: Int32 = derivedKey.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                pinData.withUnsafeBytes { pinBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pinData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        return status == kCCSuccess ? derivedKey : nil
    }

    // MARK: - Happy Path

    /// A valid QR string encrypted with the correct PIN must return Data that
    /// deserialises to a JSON object containing `public_key`, `private_key`,
    /// and `key_version` — matching the plaintext that was originally encrypted.
    ///
    /// This test performs a genuine PBKDF2-SHA256 + XSalsa20-Poly1305 round-trip.
    func test_decrypt_withValidQRAndCorrectPIN_returnsKeyPairData() throws {
        let plaintextJSON = makeKeyPairJSON()
        let qrString      = makeQRString(plaintextJSON: plaintextJSON,
                                         pin: "test-pin-1234",
                                         iterations: testIterations)

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
    /// decryption to fail with `KeyQRDecryptError.decryptionFailure`. PBKDF2
    /// will derive a different key, so the Poly1305 tag will not verify.
    func test_decrypt_withWrongPIN_throwsDecryptionFailure() {
        let qrString = makeQRString(plaintextJSON: makeKeyPairJSON(),
                                    pin: "correct-pin",
                                    iterations: testIterations)

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "wrong-pin")
        ) { error in
            guard case KeyQRDecryptError.decryptionFailure = error else {
                return XCTFail("Expected KeyQRDecryptError.decryptionFailure, got \(error)")
            }
        }
    }

    // MARK: - Malformed Payload

    /// When one of the payload fields in the QR JSON is not valid Base64, the service must
    /// throw `KeyQRDecryptError.base64DecodeFailure` before attempting any cryptographic
    /// operation.
    func test_decrypt_withInvalidBase64Payload_throwsBase64DecodeFailure() {
        // The three consecutive `!` characters are not in the Base64 alphabet.
        let outerDict: [String: Any] = [
            "v":     1,
            "alg":   "pbkdf2-sha256+xsalsa20",
            "salt":  "c2FsdHNhbHRzYWx0c2FsdA",
            "nonce": "bm9uY2Vub25jZW5vbmNlbm9uY2Vub24",
            "ct":    "not-valid-base64!!!",
            "iter":  10_000,
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

    // MARK: - Iteration count

    /// A QR that omits `iter` must be decrypted with the documented 600 000-iteration
    /// default. This is the one test that pays for a full-strength derivation; without it
    /// nothing pins the fallback to the value the exporter assumes.
    func test_decrypt_withNoIterField_usesSixHundredThousandIterationDefault() throws {
        let plaintextJSON = makeKeyPairJSON()
        let qrString = makeQRString(plaintextJSON: plaintextJSON,
                                    pin: "test-pin-1234",
                                    iterations: 600_000,
                                    includeIterField: false)

        let resultData = try KeyQRDecryptService.decrypt(qrString: qrString, pin: "test-pin-1234")

        XCTAssertEqual(resultData, Data(plaintextJSON.utf8))
    }

    /// A mismatched `iter` derives a different key, so the tag fails to verify. Guards
    /// against the field being ignored in favour of a hardcoded count.
    func test_decrypt_withWrongIterCount_throwsDecryptionFailure() {
        var qrString = makeQRString(plaintextJSON: makeKeyPairJSON(),
                                    pin: "test-pin-1234",
                                    iterations: testIterations)
        qrString = qrString.replacingOccurrences(of: "\"iter\":10000",
                                                 with: "\"iter\":10001")
        XCTAssertTrue(qrString.contains("\"iter\":10001"),
                      "Precondition: the iteration count must actually have been tampered with")

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "test-pin-1234")
        ) { error in
            guard case KeyQRDecryptError.decryptionFailure = error else {
                return XCTFail("Expected KeyQRDecryptError.decryptionFailure, got \(error)")
            }
        }
    }

    // MARK: - Unsupported Version

    /// A QR JSON where `v` is not `1` must throw
    /// `KeyQRDecryptError.unsupportedVersion` immediately, before any attempt
    /// to decode the payload fields or derive a key.
    func test_decrypt_withUnsupportedVersion_throwsUnsupportedVersion() {
        let outerDict: [String: Any] = [
            "v":     99,
            "alg":   "pbkdf2-sha256+xsalsa20",
            "salt":  "dGVzdA",  // valid base64url but irrelevant
            "nonce": "dGVzdA",
            "ct":    "dGVzdA",
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

    /// A QR JSON where `alg` is a value other than `"pbkdf2-sha256+xsalsa20"` must
    /// throw `KeyQRDecryptError.unsupportedAlgorithm`, giving callers a clear
    /// signal to upgrade the app rather than silently corrupting data.
    ///
    /// `argon2id+xchacha20` is used as the counter-example on purpose: it is the envelope an
    /// older sketch of this service expected, and a QR in that shape must be rejected outright
    /// rather than half-parsed.
    func test_decrypt_withUnsupportedAlgorithm_throwsUnsupportedAlgorithm() {
        let outerDict: [String: Any] = [
            "v":       1,
            "alg":     "argon2id+xchacha20",
            "payload": "dGVzdA==",  // the old envelope's nested payload field
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
