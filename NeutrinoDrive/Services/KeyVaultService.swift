import Foundation
import os

// MARK: - Wire types
//
// The vault endpoints are camelCase on the wire. Decode them with a plain
// JSONDecoder — the app's shared snake-case-converting decoder would rewrite
// `memoryKiB` inside the params blob and break derivation.

struct VaultUnlockMethod: Codable {
    let id: String
    /// "password" | "passkey" | "recovery"
    let method: String
    let label: String
    /// base64url( nonce || ciphertext of the master key ).
    let encryptedMasterKey: String
    /// JSON string: `Argon2Params` for password/recovery, PRF params for passkey.
    let params: String
    let createdAt: String?
    let lastUsedAt: String?
}

struct VaultResponse: Codable {
    /// base64url( nonce || ciphertext of the Curve25519 secret key ).
    let encryptedIdentity: String
    let publicKey: String
    let version: Int
    let unlocks: [VaultUnlockMethod]
}

// MARK: - Errors

enum KeyVaultError: LocalizedError {
    case notAuthenticated
    case noVault
    case methodNotEnrolled(String)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You are signed out. Sign in and try again."
        case .noVault:
            return "No encryption key has been set up for this account yet. Open Neutrino on the web to set one up."
        case .methodNotEnrolled(let method):
            return method == "recovery"
                ? "No recovery code is enrolled for this account."
                : "No encryption password is enrolled for this account."
        case .serverError(let code):
            return "The server returned an error (\(code))."
        case .decodingError:
            return "The server sent a key vault this version of the app does not understand."
        }
    }
}

// MARK: - KeyVaultService
//
// Fetches the wrapped identity key and opens it with a password or recovery
// code, then hands the result to `KeyImportService` so the rest of the app
// keeps reading keys from the Keychain exactly as before.
//
// This is what replaces pasting a key bundle in by hand: the same secret the
// user set on the web unlocks the same identity here.
//
// Not implemented on this platform: passkey (PRF) unlock. The blob is stored
// and listed, and `unlock(vault:password:)` skips it, so a passkey-only vault
// reports that no password is enrolled rather than failing obscurely.

@MainActor
final class KeyVaultService {

    weak var authService: AuthService?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "KeyVaultService")

    private static let decoder = JSONDecoder()

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    init(authService: AuthService? = nil) {
        self.authService = authService
    }

    // MARK: - Fetch

    /// The caller's vault, or nil when they have never set one up.
    func fetchVault() async throws -> VaultResponse? {
        let token = try await authorizedToken()
        guard let url = URL(string: baseURL + "/api/v1/auth/keyvault") else {
            throw KeyVaultError.serverError(statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KeyVaultError.serverError(statusCode: 0)
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw KeyVaultError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(VaultResponse.self, from: data)
        } catch {
            logger.error("fetchVault: decode failed: \(error.localizedDescription, privacy: .public)")
            throw KeyVaultError.decodingError(underlying: error)
        }
    }

    // MARK: - Unlock

    /// Unlock with the encryption password and store the identity in the Keychain.
    @discardableResult
    func unlock(vault: VaultResponse, password: String) async throws -> KeyBundle {
        try await unlock(vault: vault, secret: password, method: "password")
    }

    /// Unlock with the recovery code shown when the vault was created.
    @discardableResult
    func unlock(vault: VaultResponse, recoveryCode: String) async throws -> KeyBundle {
        try await unlock(vault: vault,
                         secret: KeyVaultCrypto.normalizeRecoveryCode(recoveryCode),
                         method: "recovery")
    }

    private func unlock(vault: VaultResponse, secret: String, method: String) async throws -> KeyBundle {
        guard let unlockMethod = vault.unlocks.first(where: { $0.method == method }) else {
            throw KeyVaultError.methodNotEnrolled(method)
        }

        let params = try decodeArgon2Params(unlockMethod.params)
        let masterKey = try KeyVaultCrypto.unwrapMasterKey(
            encryptedMasterKey: unlockMethod.encryptedMasterKey,
            secret: secret,
            params: params
        )
        let identity = try KeyVaultCrypto.openVault(
            encryptedIdentity: vault.encryptedIdentity,
            publicKeyB64URL: vault.publicKey,
            masterKey: masterKey
        )

        // Store base64url, matching what the web client writes and what the
        // existing import path already accepts.
        let bundle = KeyBundle(
            publicKey: KeyVaultCrypto.encodeBase64URL(identity.publicKey),
            privateKey: KeyVaultCrypto.encodeBase64URL(identity.secretKey),
            keyVersion: String(vault.version)
        )
        KeyImportService.storeKeys(bundle)
        logger.info("unlock: vault opened via \(method, privacy: .public)")

        // Bookkeeping only — a failure here must not fail the unlock.
        await markUsed(unlockMethod.id)
        return bundle
    }

    private func decodeArgon2Params(_ json: String) throws -> Argon2Params {
        guard let data = json.data(using: .utf8) else {
            throw KeyVaultCryptoError.invalidBase64
        }
        do {
            return try Self.decoder.decode(Argon2Params.self, from: data)
        } catch {
            throw KeyVaultError.decodingError(underlying: error)
        }
    }

    // MARK: - Bookkeeping

    private func markUsed(_ unlockID: String) async {
        guard let token = try? await authorizedToken(),
              let url = URL(string: baseURL + "/api/v1/auth/keyvault/unlocks/\(unlockID)/used")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Auth

    private func authorizedToken() async throws -> String {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw KeyVaultError.notAuthenticated
        }
        return token
    }
}
