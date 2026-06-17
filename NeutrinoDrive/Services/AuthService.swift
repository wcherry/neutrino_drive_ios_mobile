import Foundation
import CryptoKit

// MARK: - AuthError

enum AuthError: LocalizedError {
    case invalidCredentials
    case stateMismatch
    case missingCode
    case tokenExchangeFailed(String)
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case configuration

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:            return "Invalid email or password."
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

    // MARK: - Keychain Keys

    static let accessTokenKey  = "nd.access_token"
    static let refreshTokenKey = "nd.refresh_token"
    static let tokenExpiryKey  = "nd.token_expiry"

    // MARK: - OAuth Configuration

    private enum AuthConfig {
        static let baseURL      = "http://localhost:8080"
        static let loginURL     = baseURL + "/api/v1/auth/login"
        static let authorizeURL = baseURL + "/api/v1/oauth/authorize"
        static let tokenURL     = baseURL + "/api/v1/oauth/token"
        static let clientID     = "neutrino-ios"
        static let redirectURI  = "neutrinodrive://oauth/callback"
    }

    // MARK: - Init

    init() {
        isAuthenticated = KeychainService.load(forKey: AuthService.accessTokenKey) != nil
    }

    // MARK: - Public API

    func login(email: String, password: String) async {
        loginError = nil
        do {
            let sessionToken = try await step1Login(email: email, password: password)
            let (verifier, challenge) = Self.pkceValues()
            let state = Self.randomBase64URL(byteCount: 16)
            let code = try await step2Authorize(sessionToken: sessionToken, challenge: challenge, state: state, expectedState: state)
            try await step3Exchange(code: code, verifier: verifier)
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

    private func step1Login(email: String, password: String) async throws -> String {
        guard let url = URL(string: AuthConfig.loginURL) else { throw AuthError.configuration }

        struct Body: Encodable { let email: String; let password: String }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(email: email, password: password))

        let (data, response) = try await performing(request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.serverError(statusCode: 0) }

        switch http.statusCode {
        case 200...299:
            struct SessionResponse: Decodable { let accessToken: String }
            let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
            return decoded.accessToken
        case 401:
            throw AuthError.invalidCredentials
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
            return try await URLSession.shared.data(for: request)
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
