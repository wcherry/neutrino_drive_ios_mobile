import Foundation
import os.log
import NeutrinoCore
import NeutrinoAuth

// MARK: - VersionHistoryError

enum VersionHistoryError: LocalizedError {
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

// MARK: - FileVersion

/// One entry of `ListVersionsResponse.versions` (`src/drive/storage/dto.rs`).
struct FileVersion: Identifiable, Hashable {
    let id: String
    let fileID: String
    let versionNumber: Int
    let sizeBytes: Int64
    let label: String?
    let createdAt: Date
    /// True for versions explicitly saved with a name, false for automatic snapshots.
    let isNamed: Bool

    var displayName: String {
        if let label, !label.isEmpty { return label }
        return "Version \(versionNumber)"
    }
}

// MARK: - VersionHistoryService

/// Lists and restores a file's previous versions.
///
/// **Downloading a historical version is not implemented here** — it goes through
/// `DownloadService.download(fileID:fileName:mimeType:versionID:)`, so a historical version is
/// decrypted by exactly the same code as a current file. Duplicating a decrypt path was the
/// obvious way to end up with a version viewer that renders ciphertext.
///
/// ## Why the current DEK opens an old version
///
/// The server stores no per-version key: `FileVersionResponse` carries no key field, and a
/// version snapshot is a byte-for-byte `std::fs::copy` of the blob
/// (`src/drive/storage/service.rs`). `file_key_refs` holds one row per `(file_id, user_id)`.
/// Clients reuse a file's DEK across saves — the web app generates a new one only when no key
/// ref exists at all — so the stored key is the key every version was encrypted with.
///
/// The standing risk this creates is recorded in the plan: if any client ever *rotates* a
/// file's DEK, every older version becomes permanently undecryptable and nothing in the schema
/// would notice. That is a backend/web property, not something the iOS client can fix, but
/// version history is the feature that would expose it.
@MainActor
final class VersionHistoryService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var versions: [FileVersion] = []
    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Dependencies

    weak var authService: AuthService?

    private let session: URLSession

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "VersionHistoryService")

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Decoder

    /// The version DTO serialises `created_at` as an RFC 3339 / ISO 8601 `DateTime<Utc>`
    /// (note: *unlike* the file and folder DTOs elsewhere in the API, which emit a bare
    /// `NaiveDateTime` with no zone). Both fractional-second and whole-second forms are
    /// accepted so a server built with either chrono formatting still decodes.
    private static let decoder: JSONDecoder = {
        let formatters: [ISO8601DateFormatter] = {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return [withFraction, plain]
        }()
        let fallbacks: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"].map {
            let f = DateFormatter()
            f.dateFormat = $0
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            return f
        }
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                            category: "VersionHistoryService")
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            for f in formatters { if let date = f.date(from: raw) { return date } }
            for f in fallbacks  { if let date = f.date(from: raw) { return date } }
            logger.error("version date decode failed: \(raw, privacy: .public)")
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Cannot parse date: \(raw)"))
        }
        return d
    }()

    // MARK: - Load

    /// Fetch the version list, newest first.
    ///
    /// Sorted client-side on `versionNumber` rather than trusting server order: the endpoint
    /// accepts `orderBy`/`direction` parameters, so the default is not guaranteed to be the
    /// one this UI wants.
    func loadVersions(fileID: String) async {
        isLoading = true
        error = nil
        do {
            let response: APIListVersionsResponse = try await get("/api/v1/drive/files/\(fileID)/versions")
            versions = response.versions
                .map(FileVersion.init(api:))
                .sorted { $0.versionNumber > $1.versionNumber }
            logger.debug("loadVersions: \(response.versions.count) versions for \(fileID, privacy: .public)")
        } catch {
            logger.error("loadVersions failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Restore

    /// Restore the file to `versionID`.
    ///
    /// The server snapshots the *current* content as a new version first, so restoring is
    /// non-destructive and reversible. The version list is reloaded afterwards because both
    /// the restore and that snapshot change it.
    func restore(fileID: String, versionID: String) async throws {
        let _: APIFileMetadataResponse = try await post(
            "/api/v1/drive/files/\(fileID)/versions/\(versionID)/restore"
        )
        logger.debug("restore: \(fileID, privacy: .public) → version \(versionID, privacy: .public)")
        await loadVersions(fileID: fileID)
    }

    // MARK: - HTTP

    private func request(method: String, path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw VersionHistoryError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        return req
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await perform(request(method: "GET", path: path))
    }

    private func post<T: Decodable>(_ path: String) async throws -> T {
        try await perform(request(method: "POST", path: path))
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        var req = try await authorized(req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        logger.debug("--> \(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw VersionHistoryError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw VersionHistoryError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            throw VersionHistoryError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw VersionHistoryError.decodingError(underlying: error)
        }
    }

    private func authorized(_ req: URLRequest) async throws -> URLRequest {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw VersionHistoryError.notAuthenticated
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

// MARK: - Model Bridging

private extension FileVersion {
    init(api: APIFileVersionResponse) {
        self.init(id: api.id,
                  fileID: api.fileId,
                  versionNumber: api.versionNumber,
                  sizeBytes: api.sizeBytes,
                  label: api.label,
                  createdAt: api.createdAt,
                  isNamed: api.isNamed)
    }
}

// MARK: - API Models

private struct APIListVersionsResponse: Decodable {
    let versions: [APIFileVersionResponse]
}

private struct APIFileVersionResponse: Decodable {
    let id: String
    let fileId: String
    let versionNumber: Int
    let sizeBytes: Int64
    let label: String?
    let createdAt: Date
    let isNamed: Bool
}

/// The restore endpoint returns the updated file metadata. Only `id` is needed, but the
/// response is decoded rather than ignored so a malformed one surfaces as an error.
private struct APIFileMetadataResponse: Decodable {
    let id: String
}
