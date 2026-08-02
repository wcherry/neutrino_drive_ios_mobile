import Foundation
import os.log

// MARK: - DriveAPIError

enum DriveAPIError: LocalizedError {
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)
    case notFound

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:        return "You are not signed in."
        case .networkError:            return "A network error occurred. Please check your connection."
        case .serverError(let code):   return "Server error (\(code))."
        case .decodingError(let err):  return "Failed to read server response: \(err.localizedDescription)"
        case .notFound:                return "That item no longer exists."
        }
    }
}

// MARK: - Drive record DTOs
//
// Deliberately mirrors the backend's `FileResponse` / `FolderResponse` (src/drive/filesystem/dto.rs)
// rather than the app's `DriveItem`. `DriveItem` is a view model that carries UI-shaped state;
// the File Provider extension needs the wire records and nothing else.

struct DriveFileRecord: Decodable, Equatable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
    let isStarred: Bool?
}

struct DriveFolderRecord: Decodable, Equatable {
    let id: String
    let name: String
    let parentId: String?
    let updatedAt: Date
    let isStarred: Bool?
}

/// `GET /api/v1/drive/folders/{id}` returns the folder's **own** record alongside its children
/// (`FolderContentsResponse.folder`, `dto.rs:165` — "Present when listing a non-root folder").
/// That is what lets the File Provider answer `item(for:)` on a folder without a second
/// endpoint; there is no `GET /folders/{id}/metadata`.
struct DriveFolderContents: Decodable, Equatable {
    let folder: DriveFolderRecord?
    let folders: [DriveFolderRecord]
    let files: [DriveFileRecord]
}

// MARK: - FolderIDChange

/// Expresses the backend's `Option<Option<String>>` for `UpdateFileRequest.folder_id`
/// (`dto.rs:56`), which has three states and not two:
///
/// - key absent  → leave the parent alone
/// - key `null`  → move to the drive root
/// - key `"abc"` → move into folder `abc`
///
/// Swift's `String??` encodes the middle and the first identically through the synthesised
/// `Encodable`, which would turn every rename into a silent move-to-root. Hence the explicit
/// enum and the hand-written `encode(to:)` on `UpdateFileBody`.
enum FolderIDChange: Equatable {
    case unchanged
    case moveTo(String?)
}

// MARK: - DriveAPIClient

/// The drive metadata endpoints, as a plain client with no published state and no `AuthService`.
///
/// **Why this exists rather than reusing `DriveService`.** `DriveService` is `@MainActor` +
/// `ObservableObject`, owns five published collections, and holds a reference to `AuthService`
/// for token refresh. None of that can be compiled into a memory-constrained File Provider
/// extension without dragging most of the app in behind it. This is the same extraction that
/// produced `E2EEUploader` from `UploadService` in Phase 2 — see "Code-sharing strategy" in
/// `agent_docs/plans/feature-phase2-biometrics-share-background.md`.
///
/// ## No token refresh, on purpose
///
/// This client reads the access token from the shared Keychain and does **not** refresh it. Two
/// processes racing over one refresh token — the app and the extension — is a materially worse
/// failure than a clear error, because a lost race invalidates the *app's* session too. A 401
/// therefore surfaces as `.notAuthenticated` and the user resolves it by opening the app.
struct DriveAPIClient {

    // MARK: - Dependencies

    let session: URLSession

    /// Injectable so tests can stub responses with `MockURLProtocol`.
    init(session: URLSession = .shared) {
        self.session = session
    }

    private var baseURL: String { SharedStorage.serverHost }

    private var logger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive", category: "DriveAPIClient")
    }

    // MARK: - Decoder
    //
    // The backend emits `NaiveDateTime` with and without microseconds. Same two formatters as
    // `DriveService` and `E2EEUploader`; a third divergent copy would decode one shape and not
    // the other, which shows up as an empty folder rather than as an error.

    static let decoder: JSONDecoder = {
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
            // Last resort: a zoned RFC 3339 value, which the version DTOs emit.
            if let date = ISO8601DateFormatter().date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Cannot parse date: \(raw)"
            ))
        }
        return d
    }()

    // MARK: - Reads

    /// Contents of a folder, or of the drive root when `folderID` is nil.
    func listFolder(folderID: String?) async throws -> DriveFolderContents {
        let path = folderID.map { "/api/v1/drive/folders/\($0)" } ?? "/api/v1/drive"
        return try await perform(method: "GET", path: path)
    }

    /// A single file's metadata — `GET /files/{id}/metadata`.
    func fileMetadata(fileID: String) async throws -> DriveFileRecord {
        try await perform(method: "GET", path: "/api/v1/drive/files/\(fileID)/metadata")
    }

    /// Recently updated files, used to back the File Provider working set.
    func recentFiles(limit: Int) async throws -> [DriveFileRecord] {
        let response: ListFilesResponse = try await perform(
            method: "GET",
            path: "/api/v1/drive/files?orderBy=updatedAt&direction=desc&limit=\(limit)"
        )
        return response.files
    }

    // MARK: - Writes

    func createFolder(name: String, parentID: String?) async throws -> DriveFolderRecord {
        try await perform(method: "POST", path: "/api/v1/drive/folders",
                          body: CreateFolderBody(name: name, parentId: parentID))
    }

    /// Rename and/or move a file in a single request.
    ///
    /// One `PATCH` covers both because `UpdateFileRequest` carries `name` and `folder_id`
    /// together — which happens to be exactly the shape `NSFileProviderReplicatedExtension`'s
    /// `modifyItem` hands over, since it can present `.filename` and `.parentItemIdentifier`
    /// as changed fields in the same call.
    func updateFile(fileID: String,
                    name: String? = nil,
                    folderID: FolderIDChange = .unchanged) async throws -> DriveFileRecord {
        try await perform(method: "PATCH", path: "/api/v1/drive/files/\(fileID)",
                          body: UpdateFileBody(name: name, folderID: folderID))
    }

    func updateFolder(folderID: String,
                      name: String? = nil,
                      parentID: FolderIDChange = .unchanged) async throws -> DriveFolderRecord {
        try await perform(method: "PATCH", path: "/api/v1/drive/folders/\(folderID)",
                          body: UpdateFolderBody(name: name, parentID: parentID))
    }

    /// Move items to Trash.
    ///
    /// **Trash, never permanent delete.** The Files app's affordance reads "Delete" and a user
    /// will take it as destructive, but the permanent endpoint would let a mis-swipe in a system
    /// UI destroy an E2EE file that no server-side backup can recover — the server cannot read
    /// it either. Trash is recoverable and matches what the in-app delete does.
    @discardableResult
    func trash(fileIDs: [String], folderIDs: [String]) async throws -> Int {
        let result: BulkResult = try await perform(
            method: "POST", path: "/api/v1/drive/bulk/trash",
            body: BulkTrashBody(fileIds: fileIDs, folderIds: folderIDs)
        )
        return result.affected
    }

    // MARK: - HTTP

    private func perform<T: Decodable>(method: String,
                                       path: String,
                                       body: (any Encodable)? = nil) async throws -> T {
        guard let token = SharedStorage.accessToken() else {
            throw DriveAPIError.notAuthenticated
        }
        guard let url = URL(string: baseURL + path) else {
            throw DriveAPIError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                req.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw DriveAPIError.decodingError(underlying: error)
            }
        }

        logger.debug("--> \(method, privacy: .public) \(path, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw DriveAPIError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DriveAPIError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(path, privacy: .public)")

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            // The extension cannot refresh; this is the terminal state, not a retryable one.
            throw DriveAPIError.notAuthenticated
        case 404:
            throw DriveAPIError.notFound
        default:
            throw DriveAPIError.serverError(statusCode: http.statusCode)
        }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw DriveAPIError.decodingError(underlying: error)
        }
    }
}

// MARK: - Request / response bodies

private struct ListFilesResponse: Decodable {
    let files: [DriveFileRecord]
}

private struct CreateFolderBody: Encodable {
    let name: String
    let parentId: String?
}

private struct BulkTrashBody: Encodable {
    let fileIds: [String]
    let folderIds: [String]
}

private struct BulkResult: Decodable {
    let affected: Int
}

/// Hand-written `encode(to:)` so an absent `folderId` key and a `null` one stay distinguishable.
/// See `FolderIDChange` for why the synthesised conformance is unusable here.
private struct UpdateFileBody: Encodable {
    let name: String?
    let folderID: FolderIDChange

    enum CodingKeys: String, CodingKey {
        case name, folderId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let name { try c.encode(name, forKey: .name) }
        switch folderID {
        case .unchanged:            break
        case .moveTo(nil):          try c.encodeNil(forKey: .folderId)
        case .moveTo(let id?):      try c.encode(id, forKey: .folderId)
        }
    }
}

private struct UpdateFolderBody: Encodable {
    let name: String?
    let parentID: FolderIDChange

    enum CodingKeys: String, CodingKey {
        case name, parentId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let name { try c.encode(name, forKey: .name) }
        switch parentID {
        case .unchanged:            break
        case .moveTo(nil):          try c.encodeNil(forKey: .parentId)
        case .moveTo(let id?):      try c.encode(id, forKey: .parentId)
        }
    }
}
