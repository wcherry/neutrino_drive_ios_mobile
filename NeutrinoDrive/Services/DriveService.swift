import Foundation
import os.log

// MARK: - DriveError

enum DriveError: LocalizedError {
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:           return "You are not signed in."
        case .networkError:               return "A network error occurred. Please check your connection."
        case .serverError(let code):      return "Server error (\(code))."
        case .decodingError(let err):     return "Failed to read server response: \(err.localizedDescription)"
        }
    }
}

// MARK: - DriveService

@MainActor
final class DriveService: ObservableObject {

    // MARK: - Published State

    /// My Drive items (hierarchical). Also used by MoveSheet for folder picker.
    @Published private(set) var allItems: [DriveItem] = []
    /// Items from GET /api/v1/drive/files (sorted by updatedAt).
    @Published private(set) var recentItems: [DriveItem] = []
    /// Items from GET /api/v1/drive/trash.
    @Published private(set) var trashItems: [DriveItem] = []
    /// Items from GET /api/v1/drive/shared-with-me.
    @Published private(set) var sharedItems: [DriveItem] = []

    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Test Seeding

    #if DEBUG
    /// Seed state for unit tests — bypasses the network entirely.
    convenience init(myDrive: [DriveItem] = [], trash: [DriveItem] = [],
                     recents: [DriveItem] = [], shared: [DriveItem] = []) {
        self.init()
        self.allItems   = myDrive
        self.trashItems = trash
        self.recentItems = recents
        self.sharedItems = shared
    }
    #endif

    // MARK: - Shared decoder

    private static let decoder: JSONDecoder = {
        let make = { (format: String) -> DateFormatter in
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            return f
        }
        let formatters = [
            make("yyyy-MM-dd'T'HH:mm:ss.SSSSSS"),   // with microseconds
            make("yyyy-MM-dd'T'HH:mm:ss"),           // without fractional seconds
        ]
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                            category: "DriveService")
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            for formatter in formatters {
                if let date = formatter.date(from: raw) { return date }
            }
            logger.error("date decode failed: unexpected value=\(raw, privacy: .public) at \(decoder.codingPath.map(\.stringValue).joined(separator: "."), privacy: .public)")
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Cannot parse date: \(raw)"
            ))
        }
        return d
    }()

    // MARK: - Logging

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "DriveService")

    // MARK: - Configuration

    /// Set once at app launch by NeutrinoDriveApp so the service can refresh tokens before requests.
    weak var authService: AuthService?

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    // MARK: - Section Query

    func items(in section: DriveSection, parentID: String?) -> [DriveItem] {
        switch section {
        case .myDrive:  return allItems.filter { $0.parentID == parentID }
        case .recents:  return recentItems
        case .trash:    return trashItems
        case .shared:   return sharedItems
        }
    }

    // MARK: - Load

    func loadSection(_ section: DriveSection, parentID: String?) async {
        logger.debug("loadSection: \(section.rawValue, privacy: .public) parentID=\(parentID ?? "root", privacy: .public)")
        isLoading = true
        error = nil
        do {
            switch section {
            case .myDrive:
                let response: APIFolderContentsResponse
                if let id = parentID {
                    response = try await get("/api/v1/drive/folders/\(id)")
                } else {
                    response = try await get("/api/v1/drive")
                }
                let folders = response.folders.map { DriveItem(folder: $0) }
                let files   = response.files.map   { DriveItem(file: $0) }
                // Replace cached items for this parent to avoid stale duplicates.
                allItems.removeAll { $0.parentID == parentID }
                allItems.append(contentsOf: folders)
                allItems.append(contentsOf: files)
                logger.debug("loadSection myDrive: loaded \(folders.count) folders, \(files.count) files")

            case .recents:
                let response: APIListFilesResponse = try await get(
                    "/api/v1/drive/files?orderBy=updatedAt&direction=desc&limit=20"
                )
                recentItems = response.files.map { DriveItem(metadata: $0) }
                logger.debug("loadSection recents: loaded \(response.files.count) files")

            case .trash:
                let response: APITrashContentsResponse = try await get("/api/v1/drive/trash")
                trashItems = response.folders.map { DriveItem(trashFolder: $0) }
                           + response.files.map   { DriveItem(trashFile: $0) }
                logger.debug("loadSection trash: loaded \(response.folders.count) folders, \(response.files.count) files")

            case .shared:
                // The shared-with-me endpoint has no defined schema; decode best-effort.
                let response: APIFolderContentsResponse? = try? await get("/api/v1/drive/shared-with-me")
                if let response {
                    sharedItems = response.folders.map { DriveItem(folder: $0, isShared: true) }
                               + response.files.map   { DriveItem(file: $0, isShared: true) }
                    logger.debug("loadSection shared: loaded \(response.folders.count) folders, \(response.files.count) files")
                }
            }
        } catch {
            logger.error("loadSection \(section.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Mutations (fire-and-forget, optimistic)

    func createFolder(name: String, parentID: String?) {
        logger.debug("createFolder: name=\(name, privacy: .public) parentID=\(parentID ?? "root", privacy: .public)")
        let placeholder = DriveItem(
            id: UUID().uuidString, name: name, type: .folder,
            parentID: parentID, size: nil, modifiedAt: Date(),
            isTrashed: false, isShared: false, mimeType: nil
        )
        allItems.append(placeholder)
        Task {
            do {
                let body = APICreateFolderRequest(name: name, parentId: parentID)
                let created: APIFolderResponse = try await post("/api/v1/drive/folders", body: body)
                // Replace placeholder with server-assigned ID.
                if let idx = allItems.firstIndex(where: { $0.id == placeholder.id }) {
                    allItems[idx] = DriveItem(folder: created)
                }
                logger.debug("createFolder succeeded: id=\(created.id, privacy: .public)")
            } catch {
                logger.error("createFolder failed: name=\(name, privacy: .public) error=\(error, privacy: .public)")
                allItems.removeAll { $0.id == placeholder.id }
                self.error = error.localizedDescription
            }
        }
    }

    func rename(itemID: String, to newName: String) {
        guard let idx = index(of: itemID) else { return }
        let old = allItems[idx].name
        let isFolder = allItems[idx].type == .folder
        logger.debug("rename: id=\(itemID, privacy: .public) from=\(old, privacy: .public) to=\(newName, privacy: .public)")
        allItems[idx].name = newName
        allItems[idx].modifiedAt = Date()
        Task {
            do {
                if isFolder {
                    let body = APIUpdateFolderRequest(name: newName)
                    let _: APIFolderResponse = try await patch("/api/v1/drive/folders/\(itemID)", body: body)
                } else {
                    let body = APIUpdateFileRequest(name: newName)
                    let _: APIFileResponse = try await patch("/api/v1/drive/files/\(itemID)", body: body)
                }
                logger.debug("rename succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("rename failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                if let i = index(of: itemID) { allItems[i].name = old }
                self.error = error.localizedDescription
            }
        }
    }

    /// Moves the item to Trash (first call) or permanently deletes it (if already trashed).
    func delete(itemID: String) {
        if let idx = trashItems.firstIndex(where: { $0.id == itemID }) {
            let item = trashItems.remove(at: idx)
            logger.debug("delete (permanent): id=\(itemID, privacy: .public) name=\(item.name, privacy: .public)")
            Task {
                do {
                    if item.type == .folder {
                        try await deleteRequest("/api/v1/drive/trash/folders/\(itemID)")
                    } else {
                        try await deleteRequest("/api/v1/drive/trash/files/\(itemID)")
                    }
                    logger.debug("delete (permanent) succeeded: id=\(itemID, privacy: .public)")
                } catch {
                    logger.error("delete (permanent) failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                    trashItems.append(item)
                    self.error = error.localizedDescription
                }
            }
        } else if let idx = index(of: itemID) {
            let item = allItems.remove(at: idx)
            logger.debug("delete (trash): id=\(itemID, privacy: .public) name=\(item.name, privacy: .public)")
            trashItems.append(DriveItem(
                id: item.id, name: item.name, type: item.type,
                parentID: item.parentID, size: item.size, modifiedAt: Date(),
                isTrashed: true, isShared: false, mimeType: item.mimeType
            ))
            Task {
                do {
                    if item.type == .folder {
                        let body = APIBulkTrashRequest(fileIds: [], folderIds: [itemID])
                        let _: APIBulkResult = try await post("/api/v1/drive/bulk/trash", body: body)
                    } else {
                        let body = APIBulkTrashRequest(fileIds: [itemID], folderIds: [])
                        let _: APIBulkResult = try await post("/api/v1/drive/bulk/trash", body: body)
                    }
                    logger.debug("delete (trash) succeeded: id=\(itemID, privacy: .public)")
                } catch {
                    logger.error("delete (trash) failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                    trashItems.removeAll { $0.id == itemID }
                    allItems.append(item)
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func move(itemID: String, to newParentID: String?) {
        guard let idx = index(of: itemID) else { return }
        guard !isDescendant(potentialChildID: newParentID ?? "", ofFolderID: itemID) else { return }
        let oldParent = allItems[idx].parentID
        logger.debug("move: id=\(itemID, privacy: .public) to=\(newParentID ?? "root", privacy: .public)")
        allItems[idx].parentID = newParentID
        let item = allItems[idx]
        Task {
            do {
                let body = item.type == .folder
                    ? APIBulkMoveRequest(fileIds: [], folderIds: [itemID], targetFolderId: newParentID)
                    : APIBulkMoveRequest(fileIds: [itemID], folderIds: [], targetFolderId: newParentID)
                let _: APIBulkResult = try await post("/api/v1/drive/bulk/move", body: body)
                logger.debug("move succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("move failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                if let i = index(of: itemID) { allItems[i].parentID = oldParent }
                self.error = error.localizedDescription
            }
        }
    }

    func restore(itemID: String) {
        guard let idx = trashItems.firstIndex(where: { $0.id == itemID }) else { return }
        var item = trashItems.remove(at: idx)
        logger.debug("restore: id=\(itemID, privacy: .public) name=\(item.name, privacy: .public)")
        item.isTrashed = false
        allItems.append(item)
        Task {
            do {
                if item.type == .folder {
                    try await post("/api/v1/drive/trash/folders/\(itemID)/restore")
                } else {
                    try await post("/api/v1/drive/trash/files/\(itemID)/restore")
                }
                logger.debug("restore succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("restore failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                allItems.removeAll { $0.id == itemID }
                trashItems.append(item)
                self.error = error.localizedDescription
            }
        }
    }

    func emptyTrash() {
        logger.debug("emptyTrash: removing \(self.trashItems.count) items")
        let snapshot = trashItems
        trashItems = []
        Task {
            do {
                let _: APIBulkResult = try await deleteRequest("/api/v1/drive/trash")
                logger.debug("emptyTrash succeeded")
            } catch {
                logger.error("emptyTrash failed: \(error, privacy: .public)")
                trashItems = snapshot
                self.error = error.localizedDescription
            }
        }
    }

    /// Called by UploadService after a successful upload to optimistically add the file to allItems.
    func fileWasUploaded(_ result: UploadResult) {
        let item = DriveItem(
            id: result.id,
            name: result.name,
            type: .file,
            parentID: result.folderId,
            size: result.sizeBytes,
            modifiedAt: result.updatedAt,
            isTrashed: false,
            isShared: false,
            mimeType: result.mimeType
        )
        allItems.append(item)
        logger.debug("fileWasUploaded: id=\(result.id, privacy: .public) name=\(result.name, privacy: .public)")
    }

    // MARK: - Ancestry Check

    func isDescendant(potentialChildID: String, ofFolderID folderID: String) -> Bool {
        var currentID: String? = potentialChildID
        while let id = currentID {
            if id == folderID { return true }
            currentID = allItems.first(where: { $0.id == id })?.parentID
        }
        return false
    }

    // MARK: - Private Helpers

    private func index(of itemID: String) -> Int? {
        allItems.firstIndex(where: { $0.id == itemID })
    }

    // MARK: - HTTP

    /// Builds a URLRequest without an Authorization header; `perform` injects it after refresh.
    private func request(method: String, path: String, body: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw DriveError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    @discardableResult
    private func get<T: Decodable>(_ path: String) async throws -> T {
        let req = try request(method: "GET", path: path)
        return try await perform(req)
    }

    @discardableResult
    private func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let req = try request(method: "POST", path: path, body: body)
        return try await perform(req)
    }

    private func post(_ path: String) async throws {
        let req = try request(method: "POST", path: path)
        try await performVoid(req)
    }

    @discardableResult
    private func patch<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        let req = try request(method: "PATCH", path: path, body: body)
        return try await perform(req)
    }

    @discardableResult
    private func deleteRequest<T: Decodable>(_ path: String) async throws -> T {
        let req = try request(method: "DELETE", path: path)
        return try await perform(req)
    }

    private func deleteRequest(_ path: String) async throws {
        let req = try request(method: "DELETE", path: path)
        try await performVoid(req)
    }

    /// Refreshes the token if needed, injects it, executes the request, and decodes the response.
    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let req = try await authorized(req)
        logger.debug("--> \(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            logger.error("network error: \(req.url?.path ?? "?", privacy: .public) \(error, privacy: .public)")
            throw DriveError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DriveError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("server error \(http.statusCode) \(req.url?.path ?? "?", privacy: .public): \(body, privacy: .public)")
            throw DriveError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("decode error \(req.url?.path ?? "?", privacy: .public): \(error, privacy: .public) body=\(body, privacy: .public)")
            throw DriveError.decodingError(underlying: error)
        }
    }

    /// Same as `perform` but for endpoints that return no body.
    private func performVoid(_ req: URLRequest) async throws {
        let req = try await authorized(req)
        logger.debug("--> \(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            logger.error("network error: \(req.url?.path ?? "?", privacy: .public) \(error, privacy: .public)")
            throw DriveError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DriveError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("server error \(http.statusCode) \(req.url?.path ?? "?", privacy: .public): \(body, privacy: .public)")
            throw DriveError.serverError(statusCode: http.statusCode)
        }
    }

    /// Calls `refreshTokenIfNeeded`, then injects the fresh Bearer token into the request.
    private func authorized(_ req: URLRequest) async throws -> URLRequest {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            logger.error("authorized: no access token in keychain — user must re-login")
            throw DriveError.notAuthenticated
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

// MARK: - DriveItem convenience initialisers

private extension DriveItem {
    init(folder: APIFolderResponse, isShared: Bool = false) {
        self.init(
            id: folder.id,
            name: folder.name,
            type: .folder,
            parentID: folder.parentId,
            size: nil,
            modifiedAt: folder.updatedAt,
            isTrashed: false,
            isShared: isShared,
            mimeType: nil
        )
    }

    init(file: APIFileResponse, isShared: Bool = false) {
        self.init(
            id: file.id,
            name: file.name,
            type: .file,
            parentID: file.folderId,
            size: file.sizeBytes,
            modifiedAt: file.updatedAt,
            isTrashed: false,
            isShared: isShared,
            mimeType: file.mimeType
        )
    }

    init(metadata: APIFileMetadataResponse) {
        self.init(
            id: metadata.id,
            name: metadata.name,
            type: .file,
            parentID: metadata.folderId,
            size: metadata.sizeBytes,
            modifiedAt: metadata.updatedAt,
            isTrashed: false,
            isShared: false,
            mimeType: metadata.mimeType
        )
    }

    init(trashFolder: APITrashFolderItem) {
        self.init(
            id: trashFolder.id,
            name: trashFolder.name,
            type: .folder,
            parentID: nil,
            size: nil,
            modifiedAt: trashFolder.deletedAt,
            isTrashed: true,
            isShared: false,
            mimeType: nil
        )
    }

    init(trashFile: APITrashFileItem) {
        self.init(
            id: trashFile.id,
            name: trashFile.name,
            type: .file,
            parentID: nil,
            size: trashFile.sizeBytes,
            modifiedAt: trashFile.deletedAt,
            isTrashed: true,
            isShared: false,
            mimeType: trashFile.mimeType
        )
    }
}

// MARK: - API Response / Request Models

private struct APIFolderContentsResponse: Decodable {
    let files: [APIFileResponse]
    let folders: [APIFolderResponse]
}

private struct APIFolderResponse: Decodable {
    let id: String
    let name: String
    let parentId: String?
    let updatedAt: Date
}

private struct APIFileResponse: Decodable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
}

private struct APIFileMetadataResponse: Decodable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
}

private struct APITrashContentsResponse: Decodable {
    let files: [APITrashFileItem]
    let folders: [APITrashFolderItem]
}

private struct APITrashFileItem: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let deletedAt: Date
}

private struct APITrashFolderItem: Decodable {
    let id: String
    let name: String
    let deletedAt: Date
}

private struct APIListFilesResponse: Decodable {
    let files: [APIFileMetadataResponse]
}

private struct APICreateFolderRequest: Encodable {
    let name: String
    let parentId: String?
}

private struct APIUpdateFolderRequest: Encodable {
    let name: String?
}

private struct APIUpdateFileRequest: Encodable {
    let name: String?
}

private struct APIBulkTrashRequest: Encodable {
    let fileIds: [String]
    let folderIds: [String]
}

private struct APIBulkMoveRequest: Encodable {
    let fileIds: [String]
    let folderIds: [String]
    let targetFolderId: String?
}

private struct APIBulkResult: Decodable {
    let affected: Int
}
