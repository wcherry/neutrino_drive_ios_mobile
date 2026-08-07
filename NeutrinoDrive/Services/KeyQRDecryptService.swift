import Foundation
import Sodium

// MARK: - KeyQRDecryptError

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
            return "QR code format not recognised.\n\nScanned content:\n\(preview)"
        case .unsupportedVersion:    return "The QR code uses an unsupported version."
        case .unsupportedAlgorithm:  return "The QR code uses an unsupported encryption algorithm."
        case .base64DecodeFailure:   return "Failed to decode the key payload data."
        case .kdfFailure:            return "Failed to derive an encryption key from the PIN."
        case .decryptionFailure:     return "Failed to decrypt the key payload. Check your PIN and try again."
        }
    }
}

// MARK: - KeyQRDecryptService

enum KeyQRDecryptService {

    private static let sodium = Sodium()

    /// Decrypt a QR code string using the provided PIN and return the plaintext key data.
    ///
    /// Expected QR JSON format:
    ///   { "v": 1, "alg": "argon2id+xchacha20", "payload": "<base64 of inner JSON>" }
    ///
    /// where the inner JSON (itself Base64-encoded into `payload`) is:
    ///   { "salt": "<base64>", "nonce": "<base64>", "ct": "<base64>" }
    ///
    /// KDF:    Argon2id (opsLimit 2, memLimit 64 MiB), 32-byte output, 16-byte salt
    /// Cipher: XChaCha20-Poly1305 (libsodium secretBox), 24-byte nonce
    static func decrypt(qrString: String, pin: String) throws -> Data {
        // Step 1: Parse outer QR JSON.
        let trimmed = qrString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let outerData = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: outerData) as? [String: Any]
        else {
            throw KeyQRDecryptError.invalidQRFormat(raw: trimmed)
        }

        // Step 2: Validate version (accept Int or String).
        let version: Int
        if let v = json["v"] as? Int {
            version = v
        } else if let v = json["v"] as? String, let vi = Int(v) {
            version = vi
        } else {
            throw KeyQRDecryptError.unsupportedVersion
        }
        guard version == 1 else { throw KeyQRDecryptError.unsupportedVersion }

        // Step 3: Validate algorithm.
        guard let alg = json["alg"] as? String else {
            throw KeyQRDecryptError.invalidQRFormat(raw: trimmed)
        }
        guard alg == "argon2id+xchacha20" else {
            throw KeyQRDecryptError.unsupportedAlgorithm
        }

        // Step 4: Decode the outer `payload` field and parse the inner JSON it contains.
        guard
            let payloadB64 = json["payload"] as? String,
            let payloadData = Data(base64Encoded: payloadB64)
        else {
            throw KeyQRDecryptError.base64DecodeFailure
        }

        // Step 5: Decode the inner salt/nonce/ct fields.
        guard
            let inner    = try? JSONSerialization.jsonObject(with: payloadData) as? [String: String],
            let saltStr  = inner["salt"],
            let nonceStr = inner["nonce"],
            let ctStr    = inner["ct"],
            let saltData  = Data(base64Encoded: saltStr),
            let nonceData = Data(base64Encoded: nonceStr),
            let ctData    = Data(base64Encoded: ctStr)
        else {
            throw KeyQRDecryptError.base64DecodeFailure
        }

        // Step 6: Derive a 32-byte key with Argon2id.
        let saltBytes: Bytes = Array(saltData)
        let pinBytes:  Bytes = Array(pin.utf8)
        guard let keyBytes = sodium.pwHash.hash(
            outputLength: 32,
            passwd: pinBytes,
            salt: saltBytes,
            opsLimit: 2,
            memLimit: 67_108_864,
            alg: .Argon2ID13
        ) else {
            throw KeyQRDecryptError.kdfFailure
        }

        // Step 7: Decrypt with XChaCha20-Poly1305 (NaCl secretBox).
        let nonceBytes: Bytes = Array(nonceData)
        let ctBytes:    Bytes = Array(ctData)

        guard let plaintext = sodium.secretBox.open(
            authenticatedCipherText: ctBytes,
            secretKey: keyBytes,
            nonce: nonceBytes
        ) else {
            throw KeyQRDecryptError.decryptionFailure
        }

        return Data(plaintext)
    }
}

// `Data(base64URLEncoded:)` used to be redeclared privately in three files. It now lives once,
// as an internal extension, in `E2EEUploader.swift` — which the share extension also compiles.
