import Foundation
import os.log

// MARK: - SearchError

enum SearchError: LocalizedError {
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

// MARK: - SearchService

@MainActor
final class SearchService: ObservableObject {

    // MARK: - Published State

    @Published var results: [DriveItem] = []
    @Published var isSearching: Bool = false
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
                                category: "SearchService")

    // MARK: - Shared decoder
    //
    // Matches DriveService's dual-date-format custom decoding strategy since search results'
    // createdAt/updatedAt use the same ISO-ish backend format.

    private static let decoder: JSONDecoder = {
        let make = { (format: String) -> DateFormatter in
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            return f
        }
        let formatters = [
            make("yyyy-MM-dd'T'HH:mm:ss.SSSSSS"),
            make("yyyy-MM-dd'T'HH:mm:ss"),
        ]
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            for formatter in formatters {
                if let date = formatter.date(from: raw) { return date }
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Cannot parse date: \(raw)"
            ))
        }
        return d
    }()

    // MARK: - Search

    /// Searches My Drive file names via `GET /api/v1/drive/search`.
    ///
    /// An empty/whitespace-only query is a local no-op: results are cleared, no network call
    /// is made, `isSearching` is never set true, and `error` is left untouched.
    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }

        logger.debug("search: q=\(trimmed, privacy: .public)")
        isSearching = true
        error = nil
        do {
            var components = URLComponents(string: baseURL + "/api/v1/drive/search")
            components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            guard let url = components?.url else {
                throw SearchError.serverError(statusCode: 0)
            }
            let response: APISearchResponse = try await get(url)
            // The search endpoint only ever returns files (server-side constraint — see plan);
            // folders never appear here.
            results = response.items.map { DriveItem(searchItem: $0) }
            logger.debug("search succeeded: \(response.items.count) results")
        } catch {
            logger.error("search failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
        isSearching = false
    }

    // MARK: - Private HTTP

    private func get<T: Decodable>(_ url: URL) async throws -> T {
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
            throw SearchError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SearchError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("server error \(http.statusCode) \(req.url?.path ?? "?", privacy: .public): \(body, privacy: .public)")
            throw SearchError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("decode error \(req.url?.path ?? "?", privacy: .public): \(error, privacy: .public) body=\(body, privacy: .public)")
            throw SearchError.decodingError(underlying: error)
        }
    }

    /// Calls `refreshTokenIfNeeded`, then injects the fresh Bearer token into the request.
    private func authorized(_ req: URLRequest) async throws -> URLRequest {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            logger.error("authorized: no access token in keychain — user must re-login")
            throw SearchError.notAuthenticated
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

// MARK: - DriveItem convenience initialiser

private extension DriveItem {
    init(searchItem: APISearchItem) {
        self.init(
            id: searchItem.id,
            name: searchItem.name,
            type: .file,
            parentID: nil,
            size: searchItem.sizeBytes,
            modifiedAt: searchItem.updatedAt,
            isTrashed: false,
            isShared: false,
            mimeType: searchItem.mimeType
        )
    }
}

// MARK: - API Response Models

private struct APISearchResponse: Decodable {
    let items: [APISearchItem]
    let total: Int
}

private struct APISearchItem: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let createdAt: Date
    let updatedAt: Date
    let userId: String
    let snippet: String?
}
