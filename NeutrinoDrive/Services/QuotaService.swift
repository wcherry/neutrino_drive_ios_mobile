import Foundation
import os.log
import NeutrinoCore
import NeutrinoAuth

// MARK: - QuotaError

enum QuotaError: LocalizedError {
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:        return "You are not signed in."
        case .networkError:            return "A network error occurred. Please check your connection."
        case .serverError(let code):   return "Server error (\(code))."
        case .decodingError(let err):  return "Failed to read server response: \(err.localizedDescription)"
        }
    }
}

// MARK: - StorageQuota

/// `GET /api/v1/drive/quota` response. JSON keys are already camelCase on the wire, so a plain
/// `JSONDecoder()` (no `.convertFromSnakeCase`) decodes this directly — no custom CodingKeys
/// needed. `quotaBytes`/`dailyCapBytes` are nullable server-side (null = unlimited).
struct StorageQuota: Decodable {
    let usedBytes: Int64
    let dailyUploadBytes: Int64
    let quotaBytes: Int64?
    let dailyCapBytes: Int64?
}

// MARK: - QuotaService

@MainActor
final class QuotaService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var quota: StorageQuota?
    @Published var isLoading: Bool = false
    @Published var error: String?

    // MARK: - Configuration

    /// Set once at app launch (or by the owning view) so the service can refresh tokens
    /// before requests, mirroring `DriveService.authService`.
    weak var authService: AuthService?

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    // MARK: - Logging

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "QuotaService")

    // MARK: - Decoder

    private static let decoder = JSONDecoder()

    // MARK: - Refresh

    func refresh() async {
        logger.debug("refresh: fetching quota")
        isLoading = true
        error = nil
        do {
            quota = try await get("/api/v1/drive/quota")
            logger.debug("refresh succeeded")
        } catch {
            logger.error("refresh failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Private HTTP

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw QuotaError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req = try await authorized(req)

        logger.debug("--> GET \(req.url?.path ?? "?", privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            logger.error("network error: \(req.url?.path ?? "?", privacy: .public) \(error, privacy: .public)")
            throw QuotaError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("server error \(http.statusCode) \(req.url?.path ?? "?", privacy: .public): \(body, privacy: .public)")
            throw QuotaError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("decode error \(req.url?.path ?? "?", privacy: .public): \(error, privacy: .public) body=\(body, privacy: .public)")
            throw QuotaError.decodingError(underlying: error)
        }
    }

    /// Calls `refreshTokenIfNeeded`, then injects the fresh Bearer token into the request.
    private func authorized(_ req: URLRequest) async throws -> URLRequest {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            logger.error("authorized: no access token in keychain — user must re-login")
            throw QuotaError.notAuthenticated
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}
