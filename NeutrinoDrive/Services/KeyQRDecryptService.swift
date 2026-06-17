import Foundation
import Sodium

// MARK: - KeyQRDecryptError

enum KeyQRDecryptError: LocalizedError {
    case invalidQRFormat
    case unsupportedVersion
    case unsupportedAlgorithm
    case base64DecodeFailure
    case kdfFailure
    case decryptionFailure

    var errorDescription: String? {
        switch self {
        case .invalidQRFormat:       return "The QR code does not contain a valid key payload."
        case .unsupportedVersion:    return "The QR code uses an unsupported version."
        case .unsupportedAlgorithm:  return "The QR code uses an unsupported encryption algorithm."
        case .base64DecodeFailure:   return "Failed to decode the key payload data."
        case .kdfFailure:            return "Failed to derive an encryption key from the PIN."
        case .decryptionFailure:     return "Failed to decrypt the key payload. Check your PIN and try again."
        }
    }
}

// MARK: - Private payload types

private struct KeyQRPayload: Decodable {
    let v: Int
    let alg: String
    let payload: String
}

private struct KeyQRInnerPayload: Decodable {
    let salt: String
    let nonce: String
    let ct: String
}

// MARK: - KeyQRDecryptService

enum KeyQRDecryptService {

    private static let sodium = Sodium()

    /// Decrypt a QR code string using the provided PIN and return the plaintext key data.
    ///
    /// Protocol:
    ///   Outer JSON: `{ "v": 1, "alg": "argon2id+xchacha20", "payload": "<base64>" }`
    ///   Inner JSON (base64-decoded from `payload`): `{ "salt": "<base64>", "nonce": "<base64>", "ct": "<base64>" }`
    ///   KDF: Argon2id, outputLength=32, opsLimit=2, memLimit=67108864
    ///   Cipher: XChaCha20-Poly1305 via libsodium secretBox
    ///
    /// - Parameters:
    ///   - qrString: The raw string value decoded from the QR code.
    ///   - pin: The PIN used to derive the decryption key.
    /// - Returns: Plaintext `Data` (the decrypted key JSON).
    /// - Throws: `KeyQRDecryptError` on any failure.
    static func decrypt(qrString: String, pin: String) throws -> Data {
        // Step 1: JSON-decode outer QR string.
        guard
            let outerData = qrString.data(using: .utf8),
            let outer = try? JSONDecoder().decode(KeyQRPayload.self, from: outerData)
        else {
            throw KeyQRDecryptError.invalidQRFormat
        }

        // Step 2: Validate version.
        guard outer.v == 1 else {
            throw KeyQRDecryptError.unsupportedVersion
        }

        // Step 3: Validate algorithm.
        guard outer.alg == "argon2id+xchacha20" else {
            throw KeyQRDecryptError.unsupportedAlgorithm
        }

        // Step 4: Base64-decode payload bytes, interpret as UTF-8, JSON-decode inner payload.
        guard
            let payloadBytes = Data(base64Encoded: outer.payload),
            let payloadString = String(data: payloadBytes, encoding: .utf8),
            let innerData = payloadString.data(using: .utf8),
            let inner = try? JSONDecoder().decode(KeyQRInnerPayload.self, from: innerData)
        else {
            throw KeyQRDecryptError.base64DecodeFailure
        }

        // Step 5: Base64-decode salt, nonce, and ciphertext.
        guard
            let saltData  = Data(base64Encoded: inner.salt),
            let nonceData = Data(base64Encoded: inner.nonce),
            let ctData    = Data(base64Encoded: inner.ct)
        else {
            throw KeyQRDecryptError.base64DecodeFailure
        }

        let saltBytes:  Bytes = Array(saltData)
        let nonceBytes: Bytes = Array(nonceData)
        let ctBytes:    Bytes = Array(ctData)

        // Step 6: Derive a 32-byte key from the PIN using Argon2id.
        guard let pinData = pin.data(using: .utf8) else {
            throw KeyQRDecryptError.kdfFailure
        }
        let pinBytes: Bytes = Array(pinData)

        guard let derivedKey = sodium.pwHash.hash(
            outputLength: 32,
            passwd: pinBytes,
            salt: saltBytes,
            opsLimit: 2,
            memLimit: 67_108_864,
            alg: .Argon2ID13
        ) else {
            throw KeyQRDecryptError.kdfFailure
        }

        // Step 7: Decrypt with XChaCha20-Poly1305.
        // ctBytes already contains the 16-byte Poly1305 MAC tag prepended to the ciphertext.
        guard let plaintext = sodium.secretBox.open(
            authenticatedCipherText: ctBytes,
            secretKey: derivedKey,
            nonce: nonceBytes
        ) else {
            throw KeyQRDecryptError.decryptionFailure
        }

        // Step 8: Return plaintext as Data.
        return Data(plaintext)
    }
}
