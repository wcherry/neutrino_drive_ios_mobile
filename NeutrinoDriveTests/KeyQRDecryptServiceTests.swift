import XCTest
import CommonCrypto
import CryptoKit
import Foundation
import Sodium
@testable import NeutrinoDrive

/// Tests for `KeyQRDecryptService`.
///
/// The envelope this parses is produced by another implementation in another language — the web
/// app's `mobileKeyQr.ts` — so the test that matters most is not a round trip against this file's
/// own helper but `test_decrypt_opensAnEnvelopeProducedByTheWebClient`, which runs against a
/// payload captured from that module. A round trip only ever proves this file agrees with itself,
/// which it did throughout the period when every real scan failed.
final class KeyQRDecryptServiceTests: XCTestCase {

    private let sodium = Sodium()

    // MARK: - Helpers

    /// PBKDF2-SHA256, matching the service's own derivation and the web's WebCrypto call.
    private func pbkdf2(pin: String, salt: Data, iterations: Int) -> Data {
        var derived = Data(repeating: 0, count: 32)
        let password = Data(pin.utf8)
        _ = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        return derived
    }

    private func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A key pair as the inner JSON: all three fields strings, as the web emits them.
    private func makeKeyPairJSON() -> String {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let dict: [String: String] = [
            "public_key": base64URL([UInt8](priv.publicKey.rawRepresentation)),
            "private_key": base64URL([UInt8](priv.rawRepresentation)),
            "key_version": "1",
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        return String(data: data, encoding: .utf8)!
    }

    /// Build the envelope the service parses.
    ///
    /// `iterations` is low by default so the suite does not spend a second per case on a KDF whose
    /// cost is the point in production and noise here; the vector test below covers the real one.
    private func makeQRString(plaintextJSON: String,
                              pin: String,
                              iterations: Int = 1_000,
                              alg: String = "pbkdf2-sha256+xsalsa20",
                              includeIter: Bool = true) -> String {
        let salt = sodium.randomBytes.buf(length: 16)!
        let nonce = sodium.randomBytes.buf(length: 24)!
        let key = pbkdf2(pin: pin, salt: Data(salt), iterations: iterations)
        let ct = sodium.secretBox.seal(message: Array(plaintextJSON.utf8),
                                       secretKey: Array(key),
                                       nonce: nonce)!

        var outer: [String: Any] = [
            "v": 1,
            "alg": alg,
            "salt": base64URL(salt),
            "nonce": base64URL(nonce),
            "ct": base64URL(ct),
        ]
        if includeIter { outer["iter"] = iterations }
        return String(data: try! JSONSerialization.data(withJSONObject: outer), encoding: .utf8)!
    }

    // MARK: - Cross-implementation vector

    /// Captured from `web/packages/e2e-crypto/src/mobileKeyQr.ts` via its own `exportKeyQr`.
    ///
    /// This is the assertion the app was missing. The previous implementation parsed an Argon2id
    /// envelope nested under a `payload` field, which the web has not emitted since the keyring
    /// rewrite — so every scan failed as an unsupported algorithm while the round-trip tests here
    /// stayed green. A vector from the other implementation is the only thing that catches that.
    private static let webPayload = #"{"v":1,"alg":"pbkdf2-sha256+xsalsa20","salt":"_B0LpQPDfuCferScMF1Obw","nonce":"8qITmtS1LLYGibgXuWC4AbZOwNjMZ3qV","ct":"i3Gg0htKNba328kC180w2w7vw3EvPeEN_HhG0kdSGFlcS4ZMdvqEyhyLBOq7PQbmPplzrmIxL2ARCobyoNwhX1otA7S7Ne-YFtFI6rHV15PNXdNBnIwC70rzu7SVloF_JZKzny378HOAwzJ7vEKzwnopNMDp44Yyh1OMVZjKDgbP_ovpQPgvVffAbkpN8O8WQFb3IJ4yHfzzkg","iter":600000}"#
    private static let webPin = "600953"

    func test_decrypt_opensAnEnvelopeProducedByTheWebClient() throws {
        let data = try KeyQRDecryptService.decrypt(qrString: Self.webPayload, pin: Self.webPin)

        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        XCTAssertEqual(parsed["key_version"], "1")

        // The declared public half must be the secret's own, or what lands in the Keychain is a
        // pair that seals to one identity and opens another.
        let secret = try XCTUnwrap(SealedKeyCrypto.decodeBase64URL(try XCTUnwrap(parsed["private_key"])))
        let derived = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(secret))
            .publicKey.rawRepresentation
        XCTAssertEqual(SealedKeyCrypto.encodeBase64URL([UInt8](derived)), parsed["public_key"])
    }

    /// The shape this file used to require. Pinned as *rejected* so a revert is a red test.
    func test_decrypt_rejectsTheLegacyArgon2Envelope() {
        let outer: [String: Any] = [
            "v": 1,
            "alg": "argon2id+xchacha20",
            "payload": "eyJzYWx0IjoiIiwibm9uY2UiOiIiLCJjdCI6IiJ9",
        ]
        let qr = String(data: try! JSONSerialization.data(withJSONObject: outer), encoding: .utf8)!

        XCTAssertThrowsError(try KeyQRDecryptService.decrypt(qrString: qr, pin: "any")) { error in
            guard case KeyQRDecryptError.unsupportedAlgorithm = error else {
                return XCTFail("Expected unsupportedAlgorithm, got \(error)")
            }
        }
    }

    // MARK: - Round trip

    func test_decrypt_withCorrectPIN_returnsTheKeyPairVerbatim() throws {
        let plaintext = makeKeyPairJSON()
        let qr = makeQRString(plaintextJSON: plaintext, pin: "123456")

        let result = try KeyQRDecryptService.decrypt(qrString: qr, pin: "123456")

        XCTAssertEqual(result, Data(plaintext.utf8))
    }

    func test_decrypt_withWrongPIN_throwsDecryptionFailure() {
        let qr = makeQRString(plaintextJSON: makeKeyPairJSON(), pin: "111111")

        XCTAssertThrowsError(try KeyQRDecryptService.decrypt(qrString: qr, pin: "222222")) { error in
            guard case KeyQRDecryptError.decryptionFailure = error else {
                return XCTFail("Expected decryptionFailure, got \(error)")
            }
        }
    }

    /// An envelope from a build that predates the `iter` field still has to open, which is the
    /// only reason the default is stated in two places.
    func test_decrypt_withoutIter_fallsBackToTheDefaultIterationCount() throws {
        let plaintext = makeKeyPairJSON()
        let qr = makeQRString(plaintextJSON: plaintext,
                              pin: "123456",
                              iterations: KeyQRDecryptService.defaultIterations,
                              includeIter: false)

        XCTAssertEqual(try KeyQRDecryptService.decrypt(qrString: qr, pin: "123456"),
                       Data(plaintext.utf8))
    }

    // MARK: - Malformed input

    func test_decrypt_withUndecodableFields_throwsBase64DecodeFailure() {
        let outer: [String: Any] = [
            "v": 1,
            "alg": "pbkdf2-sha256+xsalsa20",
            "salt": "not valid base64!!",
            "nonce": "also not!!",
            "ct": "nor this!!",
            "iter": 1_000,
        ]
        let qr = String(data: try! JSONSerialization.data(withJSONObject: outer), encoding: .utf8)!

        XCTAssertThrowsError(try KeyQRDecryptService.decrypt(qrString: qr, pin: "any")) { error in
            guard case KeyQRDecryptError.base64DecodeFailure = error else {
                return XCTFail("Expected base64DecodeFailure, got \(error)")
            }
        }
    }

    func test_decrypt_withMissingFields_throwsBase64DecodeFailure() {
        let outer: [String: Any] = ["v": 1, "alg": "pbkdf2-sha256+xsalsa20"]
        let qr = String(data: try! JSONSerialization.data(withJSONObject: outer), encoding: .utf8)!

        XCTAssertThrowsError(try KeyQRDecryptService.decrypt(qrString: qr, pin: "any")) { error in
            guard case KeyQRDecryptError.base64DecodeFailure = error else {
                return XCTFail("Expected base64DecodeFailure, got \(error)")
            }
        }
    }

    func test_decrypt_withUnsupportedVersion_throwsUnsupportedVersion() {
        let outer: [String: Any] = ["v": 99, "alg": "pbkdf2-sha256+xsalsa20"]
        let qr = String(data: try! JSONSerialization.data(withJSONObject: outer), encoding: .utf8)!

        XCTAssertThrowsError(try KeyQRDecryptService.decrypt(qrString: qr, pin: "any")) { error in
            guard case KeyQRDecryptError.unsupportedVersion = error else {
                return XCTFail("Expected unsupportedVersion, got \(error)")
            }
        }
    }

    func test_decrypt_withGarbageQRString_throwsInvalidQRFormat() {
        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: "not json at all", pin: "any")
        ) { error in
            guard case KeyQRDecryptError.invalidQRFormat = error else {
                return XCTFail("Expected invalidQRFormat, got \(error)")
            }
        }
    }
}
