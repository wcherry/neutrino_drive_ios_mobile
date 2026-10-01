import Foundation
import os.log
import NeutrinoCore

// MARK: - PublishedKey

/// The account's **active** identity key, as the server's key directory publishes it
/// (`GET /api/v1/auth/users/{id}/public-key`).
///
/// This is the key every other client seals to and opens with. The web keeps nothing else: its
/// keyring is exactly the directory's versions, so a DEK sealed to any other key is a file the web
/// can never open.
struct PublishedKey: Equatable, Decodable {
    let publicKey: String
    let version: Int
}

// MARK: - DeviceKeyStatus

/// Whether the key in this device's Keychain is the one the account publishes.
enum DeviceKeyStatus: Equatable {
    /// It is. New work may be sealed to it, filed under `version`.
    case current(version: Int)
    /// It is not. Anything sealed to it opens on this device and nowhere else.
    case stale(published: PublishedKey)
    /// The account publishes no key at all, so there is nothing to check the device's against.
    case unpublished
}

// MARK: - DeviceKeyCheck

/// Answers "is this device's key still the account's key?" before anything is sealed to it.
///
/// ## Why this exists
///
/// Uploads used to seal to whatever public key was in the Keychain and never ask. When an
/// account's key was replaced from another device, this one kept its old key and went on sealing
/// every backed-up photo to it — and recording the ref as v1, the same number the new key has.
/// Nothing failed here: the phone could open its own uploads. Every other client got "this file's
/// key does not open with any encryption key this device holds", for 374 files over two weeks
/// before anyone looked.
///
/// The check is one small GET, cached for ``cacheLifetime`` against the exact public key it
/// checked, so a backup of a thousand photos costs one request rather than a thousand — and a key
/// imported mid-drain is checked afresh rather than riding on the old key's answer.
enum DeviceKeyCheck {

    /// How long a `.current` answer is trusted. Short: a key replaced on another device should
    /// stop this one sealing within minutes, not at the next launch.
    static let cacheLifetime: TimeInterval = 10 * 60

    private static let lock = NSLock()
    private static var cached: (storedPublicKey: String, version: Int, at: Date)?

    private static var logger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive", category: "DeviceKeyCheck")
    }

    /// Compares the stored public key with the published one. Pure, so the comparison — the part
    /// that decides whether a file will be readable anywhere else — is testable on its own.
    ///
    /// Compared as bytes, not strings: the backend emits unpadded base64url, but a key imported
    /// from a file may carry padding, and the same key must not read as two.
    static func status(storedPublicKey: String, published: PublishedKey?) -> DeviceKeyStatus {
        guard let published else { return .unpublished }
        return samePublicKey(storedPublicKey, published.publicKey)
            ? .current(version: published.version)
            : .stale(published: published)
    }

    static func samePublicKey(_ a: String, _ b: String) -> Bool {
        guard let left = SealedKeyCrypto.decodeBase64URL(a),
              let right = SealedKeyCrypto.decodeBase64URL(b) else { return false }
        return left == right
    }

    /// The status of the key stored on this device, fetching the published key unless a recent
    /// `.current` answer for this same key is cached.
    ///
    /// - Parameter fetch: performs an authorized request; injected so the share extension can
    ///   use its own transfer session and tests need no network.
    static func check(storedPublicKey: String,
                      token: String,
                      baseURL: String,
                      fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> DeviceKeyStatus {
        if let version = cachedVersion(for: storedPublicKey) {
            return .current(version: version)
        }
        let published = try await fetchPublished(token: token, baseURL: baseURL, fetch: fetch)
        let result = status(storedPublicKey: storedPublicKey, published: published)
        switch result {
        case .current(let version):
            remember(storedPublicKey: storedPublicKey, version: version)
        case .stale(let published):
            forget()
            logger.error("device key is not the account's key (account publishes v\(published.version, privacy: .public))")
        case .unpublished:
            forget()
            logger.error("account publishes no key; refusing to seal to the device's")
        }
        return result
    }

    /// The account's active key, or nil when it publishes none (404).
    static func fetchPublished(token: String,
                               baseURL: String,
                               fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> PublishedKey? {
        guard let userID = userID(fromAccessToken: token),
              let url = URL(string: baseURL + "/api/v1/auth/users/\(userID)/public-key") else {
            throw UploadError.notAuthenticated
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(req)
        } catch {
            throw UploadError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.serverError(statusCode: 0)
        }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw UploadError.serverError(statusCode: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(PublishedKey.self, from: data)
        } catch {
            throw UploadError.decodingError(underlying: error)
        }
    }

    /// The `sub` claim of a JWT access token — the caller's user id.
    ///
    /// Read here rather than through `AccessToken.currentUserID()` because the share extension
    /// compiles this file and does not link `NeutrinoAuth`. Not a verification of anything: the
    /// server checks the token on the request this id goes into.
    static func userID(fromAccessToken token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count > 1,
              let payload = Data(base64URLEncoded: String(segments[1])),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload) else { return nil }
        return claims.sub
    }

    private struct Claims: Decodable { let sub: String }

    // MARK: - Cache

    private static func cachedVersion(for storedPublicKey: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let cached, cached.storedPublicKey == storedPublicKey,
              Date().timeIntervalSince(cached.at) < cacheLifetime else { return nil }
        return cached.version
    }

    private static func remember(storedPublicKey: String, version: Int) {
        lock.lock(); defer { lock.unlock() }
        cached = (storedPublicKey, version, Date())
    }

    /// Drops any cached answer. Called when a check fails, and by tests.
    static func forget() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
    }
}
