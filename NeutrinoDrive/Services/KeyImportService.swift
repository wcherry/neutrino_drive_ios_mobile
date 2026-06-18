import Foundation
import CryptoKit

// MARK: - KeyBundle

struct KeyBundle {
    let publicKey: String
    let privateKey: String
    let keyVersion: String
}

// MARK: - KeyImportError

enum KeyImportError: LocalizedError {
    case invalidJSON
    case missingFields
    case invalidBase64
    case keyPairMismatch
    case unsupportedFormat   // PEM detected

    var errorDescription: String? {
        switch self {
        case .invalidJSON:        return "The file is not valid JSON."
        case .missingFields:      return "The key file is missing required fields."
        case .invalidBase64:      return "One or more keys contain invalid Base64 data."
        case .keyPairMismatch:    return "The public key and private key do not form a matching pair."
        case .unsupportedFormat:  return "PEM-encoded keys are not supported. Please use raw or X9.63 Base64 encoding."
        }
    }
}

// MARK: - KeyImportService

enum KeyImportService {

    static let publicKeyKeychainKey  = "nd.encryption.public_key"
    static let privateKeyKeychainKey = "nd.encryption.private_key"
    static let keyVersionKeychainKey = "nd.encryption.key_version"

    // MARK: - importKey

    /// Parse and validate JSON data containing a P-256 key pair.
    /// Throws `KeyImportError` on any validation failure.
    static func importKey(from data: Data) throws -> KeyBundle {
        // Step 1: JSON parse
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw KeyImportError.invalidJSON
        }

        // Step 2: Cast and check required fields (accept pk/sk or public_key/private_key)
        guard let dict = parsed as? [String: String] else {
            throw KeyImportError.missingFields
        }
        guard
            let publicKeyString  = dict["public_key"] ?? dict["pk"],
            let privateKeyString = dict["private_key"] ?? dict["sk"]
        else {
            throw KeyImportError.missingFields
        }
        let keyVersionString = dict["key_version"] ?? dict["v"] ?? "1"

        // Step 3: Reject PEM-encoded keys
        if publicKeyString.hasPrefix("-----BEGIN") || privateKeyString.hasPrefix("-----BEGIN") {
            throw KeyImportError.unsupportedFormat
        }

        // Step 4: Normalise Base64URL → standard Base64 and decode
        let pubData  = try decodeBase64(publicKeyString)
        let privData = try decodeBase64(privateKeyString)

        // Steps 5–8: Validate that the public and private keys form a matching pair.
        // Try Curve25519 (X25519 key agreement) first — derive public key from private and compare.
        // Fall back to Curve25519 signing (Ed25519), then P-256.
        guard Self.validateKeyPair(pubData: pubData, privData: privData) else {
            throw KeyImportError.keyPairMismatch
        }

        // Step 9: Return the bundle using the original strings as provided
        return KeyBundle(
            publicKey: publicKeyString,
            privateKey: privateKeyString,
            keyVersion: keyVersionString
        )
    }

    // MARK: - storeKeys

    /// Persist a validated KeyBundle to the Keychain.
    static func storeKeys(_ bundle: KeyBundle) {
        KeychainService.save(bundle.publicKey,  forKey: publicKeyKeychainKey)
        KeychainService.save(bundle.privateKey, forKey: privateKeyKeychainKey)
        KeychainService.save(bundle.keyVersion, forKey: keyVersionKeychainKey)
    }

    // MARK: - hasStoredKeys

    /// Returns true when all three Keychain entries are present.
    static func hasStoredKeys() -> Bool {
        KeychainService.load(forKey: publicKeyKeychainKey)  != nil &&
        KeychainService.load(forKey: privateKeyKeychainKey) != nil &&
        KeychainService.load(forKey: keyVersionKeychainKey) != nil
    }

    // MARK: - removeKeys

    /// Deletes all three Keychain entries.
    static func removeKeys() {
        KeychainService.delete(forKey: publicKeyKeychainKey)
        KeychainService.delete(forKey: privateKeyKeychainKey)
        KeychainService.delete(forKey: keyVersionKeychainKey)
    }

    // MARK: - Private helpers

    /// Returns true if pubData and privData form a valid cryptographic key pair.
    /// Tries Curve25519 key agreement (X25519), Curve25519 signing (Ed25519), and P-256 in order.
    private static func validateKeyPair(pubData: Data, privData: Data) -> Bool {
        // X25519: derive public key from private and compare directly.
        if let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privData) {
            return priv.publicKey.rawRepresentation == pubData
        }
        // Ed25519: same approach.
        if let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData) {
            return priv.publicKey.rawRepresentation == pubData
        }
        // P-256: sign a test payload and verify with the public key.
        let p256priv = (try? P256.Signing.PrivateKey(rawRepresentation: privData))
                    ?? (try? P256.Signing.PrivateKey(x963Representation: privData))
        let p256pub  = (try? P256.Signing.PublicKey(rawRepresentation: pubData))
                    ?? (try? P256.Signing.PublicKey(x963Representation: pubData))
        if let priv = p256priv, let pub = p256pub,
           let sig = try? priv.signature(for: Data("neutrino-key-validation".utf8)) {
            return pub.isValidSignature(sig, for: Data("neutrino-key-validation".utf8))
        }
        return false
    }

    /// Convert Base64URL to standard Base64, then decode to Data.
    /// Throws `KeyImportError.invalidBase64` if decoding fails.
    private static func decodeBase64(_ input: String) throws -> Data {
        // Replace Base64URL characters with standard Base64 characters
        var standard = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding to reach a multiple of 4
        let remainder = standard.count % 4
        if remainder != 0 {
            standard += String(repeating: "=", count: 4 - remainder)
        }

        guard let decoded = Data(base64Encoded: standard) else {
            throw KeyImportError.invalidBase64
        }
        return decoded
    }
}
