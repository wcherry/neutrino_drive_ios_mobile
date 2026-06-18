import Foundation
import CommonCrypto
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
    ///   { "v": 1, "alg": "pbkdf2-sha256+xsalsa20",
    ///     "salt": "<base64url>", "nonce": "<base64url>", "ct": "<base64url>",
    ///     "iter": 600000 }
    ///
    /// KDF:    PBKDF2-SHA256, iterations from "iter" field, 32-byte output
    /// Cipher: XSalsa20-Poly1305 (libsodium secretBox), 24-byte nonce
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
        guard alg == "pbkdf2-sha256+xsalsa20" else {
            throw KeyQRDecryptError.unsupportedAlgorithm
        }

        // Step 4: Decode base64url fields.
        guard
            let saltStr  = json["salt"]  as? String,
            let nonceStr = json["nonce"] as? String,
            let ctStr    = json["ct"]    as? String,
            let saltData  = Data(base64URLEncoded: saltStr),
            let nonceData = Data(base64URLEncoded: nonceStr),
            let ctData    = Data(base64URLEncoded: ctStr)
        else {
            throw KeyQRDecryptError.base64DecodeFailure
        }

        // Step 5: Read iteration count (fall back to 600 000 if absent).
        let iterations = json["iter"] as? Int ?? 600_000

        // Step 6: Derive 32-byte key with PBKDF2-SHA256.
        guard let key = pbkdf2SHA256(password: pin, salt: saltData, iterations: iterations, keyLength: 32) else {
            throw KeyQRDecryptError.kdfFailure
        }

        // Step 7: Decrypt with XSalsa20-Poly1305 (NaCl secretBox).
        let keyBytes:   Bytes = Array(key)
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

    // MARK: - PBKDF2-SHA256

    private static func pbkdf2SHA256(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data? {
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

// MARK: - Data + Base64URL

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
