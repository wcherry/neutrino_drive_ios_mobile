import Foundation
import CryptoKit

// MARK: - AuthError

enum AuthError: LocalizedError {
    case invalidCredentials
    case twoFactorRequired
    case invalidTwoFactorCode
    case stateMismatch
    case missingCode
    case tokenExchangeFailed(String)
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case configuration

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:            return "Invalid email or password."
        case .twoFactorRequired:             return "Enter the code from your authenticator app."
        case .invalidTwoFactorCode:          return "That code was not accepted. Try the current one."
        case .stateMismatch:                 return "Authorization failed — security check failed."
        case .missingCode:                   return "Authorization failed — no code returned."
        case .tokenExchangeFailed(let msg):  return "Token exchange failed: \(msg)"
        case .networkError:                  return "A network error occurred. Please check your connection."
        case .serverError(let code):         return "Server error (\(code)). Please try again later."
        case .configuration:                 return "Authentication is misconfigured."
        }
    }
}

// MARK: - AuthService

// Three-step OAuth PKCE flow (no browser required):
//   1. POST /api/v1/auth/login          → short-lived session token
//   2. GET  /api/v1/oauth/authorize     → 302 Location: <redirect_uri>?code=…&state=…
//      (Bearer session token, redirect suppressed, code read from Location header)
//   3. POST /api/v1/oauth/token         → long-lived access + refresh tokens
@MainActor
final class AuthService: ObservableObject {

    // MARK: - Published State

    @Published var isAuthenticated: Bool = false
    @Published var loginError: String?

    /// True once the server has answered a sign-in with "this account has two-factor enabled".
    ///
    /// Drives the code field in `LoginView`. It stays set until the sign-in succeeds or the user
    /// changes their email, since a wrong code has to be re-entered against the same account
    /// rather than sending the user back to the start.
    @Published var requiresTwoFactorCode: Bool = false

    // MARK: - Keychain Keys

    // Aliases for the canonical definitions in `SharedStorage`, which the share extension
    // compiles without pulling in this class. Every existing call site keeps working.
    static let accessTokenKey  = SharedStorage.Keys.accessToken
    static let refreshTokenKey = SharedStorage.Keys.refreshToken
    static let tokenExpiryKey  = "nd.token_expiry"

    // MARK: - OAuth Configuration

    static let serverHostKey = SharedStorage.Keys.serverHost
    static let defaultHost   = SharedStorage.defaultHost

    private enum AuthConfig {
        static var baseURL: String {
            UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
        }
        static var loginURL:     String { baseURL + "/api/v1/auth/login" }
        static var authorizeURL: String { baseURL + "/api/v1/oauth/authorize" }
        static var tokenURL:     String { baseURL + "/api/v1/oauth/token" }
        static let clientID    = "neutrino-ios"
        static let redirectURI = "neutrinodrive://oauth/callback"
    }

    // MARK: - Init

    /// Injectable so tests can stub network responses with `MockURLProtocol`; defaults to
    /// `.shared` in production, matching the other services. `step2Authorize` builds its own
    /// session regardless — it needs a delegate to suppress the redirect.
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        isAuthenticated = KeychainService.load(forKey: AuthService.accessTokenKey) != nil
    }

    // MARK: - Public API

    /// Sign in, optionally with a TOTP code for an account that has two-factor enabled.
    ///
    /// An account with 2FA answers step 1 with `requiresTwoFactor` and no tokens; that is not an
    /// error, it is the server asking for the second factor. `requiresTwoFactorCode` is published
    /// so the login screen can show the field, and the same call is made again with `totpCode`.
    func login(email: String, password: String, totpCode: String? = nil) async {
        loginError = nil
        do {
            let sessionToken = try await step1Login(email: email, password: password, totpCode: totpCode)
            let (verifier, challenge) = Self.pkceValues()
            let state = Self.randomBase64URL(byteCount: 16)
            let code = try await step2Authorize(sessionToken: sessionToken, challenge: challenge, state: state, expectedState: state)
            try await step3Exchange(code: code, verifier: verifier)
            requiresTwoFactorCode = false
        } catch AuthError.twoFactorRequired {
            // Only a prompt on the first pass. Once the field is on screen, an unaccepted code
            // comes back the same way, and repeating "enter the code" reads as though nothing
            // happened at all.
            loginError = requiresTwoFactorCode
                ? AuthError.invalidTwoFactorCode.localizedDescription
                : nil
            requiresTwoFactorCode = true
        } catch let error as AuthError {
            loginError = error.localizedDescription
        } catch {
            loginError = error.localizedDescription
        }
    }

    func logout() {
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        KeychainService.delete(forKey: AuthService.refreshTokenKey)
        KeychainService.delete(forKey: AuthService.tokenExpiryKey)
        isAuthenticated = false
        loginError = nil
        requiresTwoFactorCode = false
    }

    func accessToken() -> String? {
        KeychainService.load(forKey: AuthService.accessTokenKey)
    }

    func refreshTokenIfNeeded() async {
        if let raw = KeychainService.load(forKey: AuthService.tokenExpiryKey),
           let expiry = ISO8601DateFormatter().date(from: raw),
           expiry.timeIntervalSinceNow > 60 {
            return
        }

        guard let refreshToken = KeychainService.load(forKey: AuthService.refreshTokenKey) else {
            logout()
            return
        }

        do {
            let body: [String: String] = [
                "grant_type":    "refresh_token",
                "refresh_token": refreshToken,
                "client_id":     AuthConfig.clientID,
            ]
            let response = try await postToken(formFields: body)
            persist(response)
        } catch AuthError.invalidCredentials {
            logout()
        } catch {
            print("[AuthService] Refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Step 1: Session login

    private func step1Login(email: String, password: String, totpCode: String?) async throws -> String {
        guard let url = URL(string: AuthConfig.loginURL) else { throw AuthError.configuration }

        // `totpCode` is omitted rather than sent empty: the server's field is an `Option<String>`,
        // and an empty string is a code that was supplied and is wrong.
        struct Body: Encodable {
            let email: String
            let password: String
            let totpCode: String?
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Body(email: email,
                 password: password,
                 totpCode: totpCode?.trimmingCharacters(in: .whitespaces).nilIfEmpty)
        )

        let (data, response) = try await performing(request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.serverError(statusCode: 0) }

        switch http.statusCode {
        case 200...299:
            // The tokens are flattened alongside `requiresTwoFactor` and absent when the server
            // wants a second factor, so both halves are optional here. Decoding `accessToken` as
            // required is what used to turn "2FA is on for this account" into an unreadable
            // decoding error with no way forward.
            struct SessionResponse: Decodable {
                let accessToken: String?
                let requiresTwoFactor: Bool?
            }
            let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
            if let token = decoded.accessToken { return token }
            if decoded.requiresTwoFactor == true { throw AuthError.twoFactorRequired }
            throw AuthError.serverError(statusCode: http.statusCode)
        case 401:
            // A rejected TOTP code arrives as a 401 like any other bad credential. Once the code
            // field is up, the credentials are known good, so this is the code.
            throw requiresTwoFactorCode ? AuthError.twoFactorRequired : AuthError.invalidCredentials
        default:
            throw AuthError.serverError(statusCode: http.statusCode)
        }
    }

    // MARK: - Step 2: Authorize (no redirect follow)

    private func step2Authorize(
        sessionToken: String,
        challenge: String,
        state: String,
        expectedState: String
    ) async throws -> String {
        guard var components = URLComponents(string: AuthConfig.authorizeURL) else { throw AuthError.configuration }
        components.queryItems = [
            URLQueryItem(name: "client_id",             value: AuthConfig.clientID),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "redirect_uri",          value: AuthConfig.redirectURI),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state",                 value: state),
        ]
        guard let url = components.url else { throw AuthError.configuration }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

        // Suppress redirect so we can read the Location header ourselves
        let config = URLSessionConfiguration.default
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let (data, response) = try await session.data(for: request, delegate: nil)

        guard let http = response as? HTTPURLResponse,
              (300...399).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let redirectURL = URL(string: location),
              let redirectComponents = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false),
              let code = redirectComponents.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw AuthError.tokenExchangeFailed(body)
        }

        let returnedState = redirectComponents.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        guard returnedState == expectedState else { throw AuthError.stateMismatch }

        return code
    }

    // MARK: - Step 3: Exchange code for tokens

    private func step3Exchange(code: String, verifier: String) async throws {
        let body: [String: String] = [
            "grant_type":    "authorization_code",
            "code":          code,
            "code_verifier": verifier,
            "redirect_uri":  AuthConfig.redirectURI,
            "client_id":     AuthConfig.clientID,
        ]
        let response = try await postToken(formFields: body)
        persist(response)
    }

    // MARK: - Token endpoint

    private func postToken(formFields: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: AuthConfig.tokenURL) else { throw AuthError.configuration }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formFields
            .map { k, v in "\(k)=\(formEncode(v))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await performing(request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.serverError(statusCode: 0) }

        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        case 401:
            throw AuthError.invalidCredentials
        default:
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw AuthError.tokenExchangeFailed(body)
        }
    }

    // MARK: - Helpers

    private func performing(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw AuthError.networkError(underlying: error)
        }
    }

    private func persist(_ response: TokenResponse) {
        KeychainService.save(response.accessToken,  forKey: AuthService.accessTokenKey)
        KeychainService.save(response.refreshToken, forKey: AuthService.refreshTokenKey)
        let expiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        KeychainService.save(ISO8601DateFormatter().string(from: expiry), forKey: AuthService.tokenExpiryKey)
        isAuthenticated = true
    }

    // MARK: - Encoding Helpers

    private static func base64URLEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - PKCE

    private static func pkceValues() -> (verifier: String, challenge: String) {
        let verifier = Self.randomBase64URL(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Self.base64URLEncode(Data(digest))
        return (verifier, challenge)
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Self.base64URLEncode(Data(bytes))
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Redirect suppression

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Helpers

private extension String {
    /// `nil` for an empty string, so an untouched text field encodes as an absent JSON field
    /// rather than a supplied-and-wrong value.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Models

private struct TokenResponse: Decodable {
    let accessToken:  String
    let refreshToken: String
    let expiresIn:    Int
    let tokenType:    String

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case tokenType    = "token_type"
    }
}
