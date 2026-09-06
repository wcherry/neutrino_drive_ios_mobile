import Foundation
import Sodium
import os.log
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto

// MARK: - SharingError

enum SharingError: LocalizedError {
    case notAuthenticated
    case noEncryptionKey
    case userNotFound(email: String)
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)
    /// The permission was granted, but the file's DEK could not be re-wrapped for the
    /// recipient — so they can see the file and cannot decrypt it. Deliberately its own case:
    /// this is a *partial* success and must never be reported as a plain failure or a plain
    /// success.
    case keyShareFailed(recipientName: String, reason: KeyShareFailureReason)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You are not signed in."
        case .noEncryptionKey:
            return "No encryption key found. Import your key before sharing files."
        case .userNotFound(let email):
            return "No Neutrino account found for \(email)."
        case .networkError:
            return "A network error occurred. Please check your connection."
        case .serverError(let code):
            return "Server error (\(code))."
        case .decodingError(let err):
            return "Failed to read server response: \(err.localizedDescription)"
        case .keyShareFailed(let name, let reason):
            return "Shared with \(name), but they cannot decrypt it yet — \(reason.explanation)"
        }
    }
}

/// Why a DEK re-wrap could not be completed. Each maps to a genuinely different user story,
/// which is why this is not just a string.
enum KeyShareFailureReason {
    /// The recipient has never registered a Curve25519 public key (no client set up).
    case recipientHasNoPublicKey
    /// We hold no key ref for this file — it was never encrypted (e.g. uploaded plaintext).
    case fileHasNoKey
    /// We could not unseal our own copy of the DEK.
    case cannotUnsealOwnKey
    /// The recipient's public key was malformed or not 32 bytes.
    case recipientPublicKeyInvalid
    case server(statusCode: Int)

    var explanation: String {
        switch self {
        case .recipientHasNoPublicKey:
            return "they have not set up an encryption key yet. Ask them to sign in to Neutrino Drive and import their key, then share again."
        case .fileHasNoKey:
            return "this file has no encryption key stored."
        case .cannotUnsealOwnKey:
            return "your encryption key could not open this file's key."
        case .recipientPublicKeyInvalid:
            return "their encryption key is not valid."
        case .server(let code):
            return "the server rejected the key share (\(code))."
        }
    }
}

// MARK: - Models

/// A user returned by the lookup/search endpoints (`UserLookupResponse`).
struct SharingUser: Identifiable, Hashable, Decodable {
    let id: String
    let email: String
    let name: String
}

/// Roles accepted by the permissions endpoints. The Rust `Role` enum serialises
/// `rename_all = "camelCase"`, and every variant is a single lowercase word.
enum ShareRole: String, CaseIterable, Identifiable, Codable {
    case viewer
    case commenter
    case editor
    /// Present so an existing owner permission decodes, but never offered in the picker.
    case owner

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .viewer:    return "Viewer"
        case .commenter: return "Commenter"
        case .editor:    return "Editor"
        case .owner:     return "Owner"
        }
    }

    /// Roles a user can actually be granted. Ownership transfer is a separate endpoint.
    static var assignable: [ShareRole] { [.viewer, .commenter, .editor] }
}

/// One row of `ListPermissionsResponse.permissions`.
struct SharePermission: Identifiable, Hashable {
    let id: String
    let userID: String
    let userEmail: String
    let userName: String
    let role: ShareRole
}

/// A share link (`ShareLinkResponse`). Only the fields the client uses are modelled.
struct ShareLink: Hashable {
    let token: String
    let role: String
    let visibility: String
    let isActive: Bool

    /// The web app's link route. The host comes from the configured server, so a self-hosted
    /// deployment produces a link into that deployment.
    func url(baseURL: String) -> URL? {
        URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/share/" + token)
    }
}

/// Which kind of resource is being shared. Files and folders have parallel endpoints, and
/// only files carry a DEK.
enum ShareResourceType: String {
    case file
    case folder

    var pathSegment: String {
        switch self {
        case .file:   return "files"
        case .folder: return "folders"
        }
    }
}

// MARK: - SharingService

/// Sharing: permissions, share links, recipient lookup, and — the part that actually matters —
/// re-wrapping a file's DEK to the recipient's public key so end-to-end encryption survives
/// being shared.
///
/// ## The protocol, and why the order is not negotiable
///
/// Adding a person to a **file** is a seven-step sequence:
///
/// 1. `GET  /api/v1/auth/users/lookup?email=…`            → the recipient's id/email/name
/// 2. `POST /api/v1/drive/{files|folders}/{id}/permissions` → grant access
/// 3. `GET  /api/v1/drive/files/{id}/key`                 → our sealed copy of the DEK
/// 4. unseal it with our own keypair                       → the raw DEK
/// 5. `GET  /api/v1/auth/users/{recipientId}/public-key`  → their Curve25519 public key
/// 6. re-seal the DEK to that key                          → a new sealed key
/// 7. `POST /api/v1/drive/files/{id}/key/share`           → store it for them
///
/// **Step 2 must happen before step 7.** `EncryptionService::share_file_key` in the backend
/// rejects a key share with `400 RECIPIENT_NO_ACCESS` unless the recipient already holds a
/// permission on the file. Inverting the order produces a granted permission with no key —
/// a recipient who sees the file listed and cannot open it. `SharingServiceTests` asserts the
/// recorded request order for exactly this reason.
///
/// **Folders skip steps 3–7 entirely** — there is no folder-level DEK.
///
/// ## Partial success is reported, not swallowed
///
/// The web client's `ShareDialog` fails silently when either party has no keypair. That is a
/// reasonable choice with a developer console open and a bad one on a phone: the whole point
/// of this feature is that the recipient can decrypt. So a failed re-wrap throws
/// `SharingError.keyShareFailed` **with the permission left in place**, and the sheet explains
/// what the recipient must do.
@MainActor
final class SharingService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var permissions: [SharePermission] = []
    @Published private(set) var shareLink: ShareLink?
    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Dependencies

    weak var authService: AuthService?

    private let session: URLSession

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "SharingService")

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    /// - Parameter session: injectable so tests can stub responses with `MockURLProtocol`.
    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Permissions

    func loadPermissions(resourceType: ShareResourceType, resourceID: String) async {
        isLoading = true
        error = nil
        do {
            let response: APIListPermissionsResponse = try await get(
                "/api/v1/drive/\(resourceType.pathSegment)/\(resourceID)/permissions"
            )
            permissions = response.permissions.map(SharePermission.init(api:))
            logger.debug("loadPermissions: \(response.permissions.count) entries")
        } catch {
            logger.error("loadPermissions failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Look up a user by email, grant them access, and — for files — re-wrap the DEK.
    ///
    /// Throws `SharingError.keyShareFailed` when the permission succeeded but the key did not,
    /// so the caller can show a partial-success message rather than implying either total
    /// success or total failure.
    func addPerson(email: String,
                   role: ShareRole,
                   resourceType: ShareResourceType,
                   resourceID: String) async throws {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 1 — resolve the recipient.
        let user: SharingUser
        do {
            user = try await get("/api/v1/auth/users/lookup?email=\(urlEncoded(trimmed))")
        } catch SharingError.serverError(let code) where code == 404 {
            throw SharingError.userNotFound(email: trimmed)
        }

        // Step 2 — grant the permission. Must precede the key share.
        let grant = APIGrantPermissionRequest(userId: user.id,
                                              userEmail: user.email,
                                              userName: user.name,
                                              role: role.rawValue)
        let granted: APIPermissionResponse = try await post(
            "/api/v1/drive/\(resourceType.pathSegment)/\(resourceID)/permissions",
            body: grant
        )
        permissions.removeAll { $0.userID == user.id }
        permissions.append(SharePermission(api: granted))
        logger.debug("addPerson: granted \(role.rawValue, privacy: .public) to \(user.id, privacy: .public)")

        // Steps 3–7 — files only.
        guard resourceType == .file else { return }
        if let reason = await shareFileKey(fileID: resourceID, recipient: user) {
            logger.error("addPerson: key share failed for \(user.id, privacy: .public)")
            throw SharingError.keyShareFailed(recipientName: user.name.isEmpty ? user.email : user.name,
                                              reason: reason)
        }
    }

    /// Re-wrap the file's DEK to `recipient`'s public key and store it server-side.
    ///
    /// Returns `nil` on success, or the reason it could not be done. Returning rather than
    /// throwing keeps the partial-success distinction explicit at the one call site that
    /// cares.
    func shareFileKey(fileID: String, recipient: SharingUser) async -> KeyShareFailureReason? {
        // Step 3 — our own sealed copy of the DEK.
        let ourKey: APIFileKeyResponse
        do {
            ourKey = try await get("/api/v1/drive/files/\(fileID)/key")
        } catch SharingError.serverError(let code) where code == 404 {
            // No key ref: the file was never encrypted. Nothing to share.
            return .fileHasNoKey
        } catch {
            return .server(statusCode: statusCode(of: error))
        }

        // Step 4 — unseal with the keypair the ref names. A file sealed before a rotation needs
        // the retired key, which this device holds only if the account's key file has been pulled
        // down (`KeyFileService`); without it, sharing an older file fails here rather than
        // producing something the recipient cannot open.
        guard case .found = SealedKeyCrypto.storedKeyPair(forVersion: ourKey.keyVersion ?? 1) else {
            return .cannotUnsealOwnKey
        }
        guard let dek: Bytes = SealedKeyCrypto.openDEKWithStoredKeys(
            sealedBase64URL: ourKey.encryptedFileKey,
            keyVersion: ourKey.keyVersion ?? 1
        ) else {
            return .cannotUnsealOwnKey
        }

        // Step 5 — the recipient's public key.
        let recipientKey: APIPublicKeyResponse
        do {
            recipientKey = try await get("/api/v1/auth/users/\(recipient.id)/public-key")
        } catch SharingError.serverError(let code) where code == 404 {
            return .recipientHasNoPublicKey
        } catch {
            return .server(statusCode: statusCode(of: error))
        }

        // Step 6 — re-seal to them. `SealedKeyCrypto.seal` refuses a malformed or
        // wrong-length key rather than producing ciphertext nobody can open.
        guard let resealed = SealedKeyCrypto.seal(dek: dek,
                                                  toPublicKeyBase64URL: recipientKey.publicKey) else {
            return .recipientPublicKeyInvalid
        }

        // Step 7 — store it for the recipient, against *their* key version. Recording our own
        // there, or letting the server default it to 1, is how a recipient who has rotated ends up
        // reaching for a key that never opened this DEK.
        do {
            let body = APIShareFileKeyRequest(recipientId: recipient.id,
                                              encryptedFileKey: resealed,
                                              keyVersion: recipientKey.version ?? 1)
            let _: APIFileKeyResponse = try await post("/api/v1/drive/files/\(fileID)/key/share",
                                                       body: body)
            logger.debug("shareFileKey: DEK re-wrapped for \(recipient.id, privacy: .public)")
            return nil
        } catch {
            return .server(statusCode: statusCode(of: error))
        }
    }

    func updateRole(userID: String,
                    to role: ShareRole,
                    resourceType: ShareResourceType,
                    resourceID: String) async throws {
        let body = APIUpdatePermissionRequest(role: role.rawValue)
        let updated: APIPermissionResponse = try await patch(
            "/api/v1/drive/\(resourceType.pathSegment)/\(resourceID)/permissions/\(userID)",
            body: body
        )
        if let index = permissions.firstIndex(where: { $0.userID == userID }) {
            permissions[index] = SharePermission(api: updated)
        }
    }

    /// Revoke a permission. The backend also drops the recipient's key ref.
    ///
    /// Note this is **not** forward secrecy: a recipient who already fetched the DEK keeps it.
    /// Real revocation needs re-encryption under a fresh key — see the plan's "Known gaps".
    func revoke(userID: String,
                resourceType: ShareResourceType,
                resourceID: String) async throws {
        try await deleteRequest(
            "/api/v1/drive/\(resourceType.pathSegment)/\(resourceID)/permissions/\(userID)"
        )
        permissions.removeAll { $0.userID == userID }
        logger.debug("revoke: removed \(userID, privacy: .public)")
    }

    // MARK: - Share Links

    /// Create (or replace) a share link.
    ///
    /// Uses `PUT`, which is what the backend actually exposes — `#[put("/files/{file_id}/share-link")]`.
    ///
    /// Deliberately **not** called just to display state: `GET /share-link` has a side effect —
    /// it creates a default `anyoneWithLink`/`viewer` link when none exists — so merely opening
    /// the share sheet must not touch it.
    func createShareLink(resourceType: ShareResourceType,
                         resourceID: String,
                         role: ShareRole = .viewer) async throws -> ShareLink {
        // The request enum serialises camelCase: "anyoneWithLink".
        let body = APIUpsertShareLinkRequest(visibility: "anyoneWithLink", role: role.rawValue)
        let response: APIShareLinkResponse = try await put(
            "/api/v1/drive/\(resourceType.pathSegment)/\(resourceID)/share-link",
            body: body
        )
        let link = ShareLink(token: response.token,
                             role: response.role,
                             visibility: response.visibility,
                             isActive: response.isActive)
        shareLink = link
        return link
    }

    func deleteShareLink(resourceType: ShareResourceType, resourceID: String) async throws {
        try await deleteRequest("/api/v1/drive/\(resourceType.pathSegment)/\(resourceID)/share-link")
        shareLink = nil
    }

    func shareLinkURL(_ link: ShareLink) -> URL? { link.url(baseURL: baseURL) }

    // MARK: - User Search

    func searchUsers(query: String) async -> [SharingUser] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            let results: [SharingUser] = try await get("/api/v1/auth/users/search?q=\(urlEncoded(trimmed))")
            return results
        } catch {
            logger.error("searchUsers failed: \(error, privacy: .public)")
            return []
        }
    }

    // MARK: - Reset

    /// Clears per-resource state so a reused service instance cannot show a previous file's
    /// permissions while the new ones load.
    func reset() {
        permissions = []
        shareLink = nil
        error = nil
    }

    // MARK: - HTTP

    private func urlEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private func statusCode(of error: Error) -> Int {
        if case SharingError.serverError(let code) = error { return code }
        return 0
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func request(method: String, path: String, body: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw SharingError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await perform(request(method: "GET", path: path))
    }

    private func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        try await perform(request(method: "POST", path: path, body: body))
    }

    private func put<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await perform(request(method: "PUT", path: path, body: body))
    }

    private func patch<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await perform(request(method: "PATCH", path: path, body: body))
    }

    private func deleteRequest(_ path: String) async throws {
        try await performVoid(request(method: "DELETE", path: path))
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, _) = try await execute(req)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            logger.error("decode error \(req.url?.path ?? "?", privacy: .public): \(error, privacy: .public)")
            throw SharingError.decodingError(underlying: error)
        }
    }

    private func performVoid(_ req: URLRequest) async throws {
        _ = try await execute(req)
    }

    private func execute(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let req = try await authorized(req)
        logger.debug("--> \(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            logger.error("network error: \(req.url?.path ?? "?", privacy: .public) \(error, privacy: .public)")
            throw SharingError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SharingError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            throw SharingError.serverError(statusCode: http.statusCode)
        }
        return (data, http)
    }

    private func authorized(_ req: URLRequest) async throws -> URLRequest {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw SharingError.notAuthenticated
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

// MARK: - Model Bridging

private extension SharePermission {
    init(api: APIPermissionResponse) {
        self.init(id: api.id,
                  userID: api.userId,
                  userEmail: api.userEmail,
                  userName: api.userName,
                  role: ShareRole(rawValue: api.role) ?? .viewer)
    }
}

// MARK: - API Models

private struct APIListPermissionsResponse: Decodable {
    let permissions: [APIPermissionResponse]
}

private struct APIPermissionResponse: Decodable {
    let id: String
    let userId: String
    let userEmail: String
    let userName: String
    let role: String
}

private struct APIGrantPermissionRequest: Encodable {
    let userId: String
    let userEmail: String
    let userName: String
    let role: String
}

private struct APIUpdatePermissionRequest: Encodable {
    let role: String
}

private struct APIFileKeyResponse: Decodable {
    let fileId: String
    let userId: String
    let encryptedFileKey: String
    /// Which of *our* identity versions the DEK is sealed to. Optional so a server that predates
    /// versioning still decodes; read as 1, matching the column's own default.
    let keyVersion: Int?
}

private struct APIShareFileKeyRequest: Encodable {
    let recipientId: String
    let encryptedFileKey: String
    /// The *recipient's* key version, not ours — it is what they resolve the sealed DEK against.
    let keyVersion: Int
}

private struct APIPublicKeyResponse: Decodable {
    let userId: String
    let publicKey: String
    /// Which entry of the user's keyring this is. The field is `version` on the wire, not
    /// `keyVersion` — see `PublicKeyResponse` in `src/auth/dto.rs`. Optional: a server that
    /// predates versioning omits it, and those published exactly one key, which is version 1.
    let version: Int?
}

private struct APIUpsertShareLinkRequest: Encodable {
    let visibility: String
    let role: String
}

private struct APIShareLinkResponse: Decodable {
    let token: String
    let role: String
    let visibility: String
    let isActive: Bool
}
