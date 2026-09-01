import Foundation
import CommonCrypto
import Sodium

// MARK: - KeyQRDecryptService
//
// The PIN-protected key code the web app shows under Settings → Encryption →
// "Key code for mobile".
//
// This is the enrolment path for a phone. The web client no longer offers the
// sender half of the two-QR pairing handshake — a desktop browser has no camera
// pointed at a phone — so a QR the phone *scans* is the only way a key reaches
// this device other than the recovery kit.
//
// ── What this costs, stated plainly ──────────────────────────────────────────
// The whole keypair travels in one QR under PBKDF2 over six digits. A photograph
// of the code plus an offline grind of the PIN yields the identity: 600 000
// iterations against a six-digit space is minutes on a consumer GPU, not the
// seconds a bare hash would take, but it is not a boundary to lean on. The web
// side keeps the code on screen for two minutes and says so; nothing here should
// persist the scanned string or the PIN beyond the import.
//
// ── Envelope ─────────────────────────────────────────────────────────────────
// Byte for byte what `web/packages/e2e-crypto/src/mobileKeyQr.ts` emits. Every
// field is base64url without padding, and the fields sit at the top level rather
// than nested inside a base64 `payload`.
//
//   { "v": 1, "alg": "pbkdf2-sha256+xsalsa20",
//     "salt": "…", "nonce": "…", "ct": "…", "iter": 600000 }
//
// KDF     PBKDF2-SHA256 over the PIN, 32-byte output
// Cipher  XSalsa20-Poly1305 (libsodium secretbox), 24-byte nonce, combined
//         MAC||ciphertext — which is what `secretBox.open` expects
//
// This app previously parsed an Argon2id envelope nested under `payload`, which
// the web has not produced since the keyring rewrite; every scan failed as an
// unsupported algorithm. Notes, Docs and Sheets carry the same PBKDF2 parse.
//
// The plaintext is `{ "public_key", "private_key", "key_version" }` with **all
// three as strings**; `key_version` is the keyring version the key belongs to,
// not an envelope format version. `KeyImportService` parses it.

enum KeyQRDecryptError: LocalizedError {
    case invalidQRFormat(raw: String)
    case unsupportedVersion
    case unsupportedAlgorithm
    case base64DecodeFailure
    case kdfFailure
    case decryptionFailure

    var errorDescription: String? {
        switch self {
        case .invalidQRFormat(let raw):
            let preview = raw.isEmpty ? "(empty)" : String(raw.prefix(120))
            return "That is not a Neutrino key code.\n\nScanned content:\n\(preview)"
        case .unsupportedVersion:
            return "That key code was made by a newer version of Neutrino."
        case .unsupportedAlgorithm:
            return "That key code uses an encryption method this app does not know."
        case .base64DecodeFailure:
            return "That key code is damaged and could not be read."
        case .kdfFailure:
            return "Could not derive a key from the PIN."
        case .decryptionFailure:
            return "Could not open the key code. Check the PIN and try again."
        }
    }
}

enum KeyQRDecryptService {

    private static let sodium = Sodium()

    /// Matches the web side's fallback, so a code generated without `iter` still opens.
    static let defaultIterations = 600_000

    /// Open a scanned envelope with the PIN shown beside it, returning the inner key JSON.
    ///
    /// Blocking, by design: `defaultIterations` rounds of PBKDF2 is roughly a second on a phone.
    /// Callers run it off the main actor rather than this hiding the cost behind an async
    /// signature it does not need.
    static func decrypt(qrString: String, pin: String) throws -> Data {
        let trimmed = qrString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let outerData = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: outerData) as? [String: Any]
        else {
            throw KeyQRDecryptError.invalidQRFormat(raw: trimmed)
        }

        // Accept a numeric or a string `v`: the field is a number today, and rejecting the other
        // spelling would be a needlessly brittle parse.
        let version: Int
        if let v = json["v"] as? Int {
            version = v
        } else if let v = json["v"] as? String, let parsed = Int(v) {
            version = parsed
        } else {
            throw KeyQRDecryptError.unsupportedVersion
        }
        guard version == 1 else { throw KeyQRDecryptError.unsupportedVersion }

        guard let alg = json["alg"] as? String else {
            throw KeyQRDecryptError.invalidQRFormat(raw: trimmed)
        }
        guard alg == "pbkdf2-sha256+xsalsa20" else {
            throw KeyQRDecryptError.unsupportedAlgorithm
        }

        guard let saltString = json["salt"] as? String,
              let nonceString = json["nonce"] as? String,
              let ciphertextString = json["ct"] as? String,
              let salt = SealedKeyCrypto.decodeBase64URL(saltString),
              let nonce = SealedKeyCrypto.decodeBase64URL(nonceString),
              let ciphertext = SealedKeyCrypto.decodeBase64URL(ciphertextString)
        else {
            throw KeyQRDecryptError.base64DecodeFailure
        }

        let iterations = json["iter"] as? Int ?? defaultIterations

        guard let key = pbkdf2SHA256(password: pin,
                                     salt: Data(salt),
                                     iterations: iterations,
                                     keyLength: 32) else {
            throw KeyQRDecryptError.kdfFailure
        }

        guard let plaintext = sodium.secretBox.open(authenticatedCipherText: ciphertext,
                                                    secretKey: Array(key),
                                                    nonce: nonce) else {
            throw KeyQRDecryptError.decryptionFailure
        }
        return Data(plaintext)
    }

    // MARK: - PBKDF2
    //
    // CommonCrypto rather than libsodium: swift-sodium has no PBKDF2, and matching the web side's
    // WebCrypto derivation exactly is the whole point — a different KDF here is an envelope this
    // app cannot open however correct the rest of it is.

    private static func pbkdf2SHA256(password: String,
                                     salt: Data,
                                     iterations: Int,
                                     keyLength: Int) -> Data? {
        guard let passwordData = password.data(using: .utf8) else { return nil }
        var derivedKey = Data(repeating: 0, count: keyLength)

        let status: Int32 = derivedKey.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? derivedKey : nil
    }
}

// `Data(base64URLEncoded:)` used to be redeclared privately in three files. It now lives once,
// as an internal extension, in `E2EEUploader.swift` — which the share extension also compiles.
