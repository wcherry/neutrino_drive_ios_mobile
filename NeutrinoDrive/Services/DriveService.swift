import Foundation
import os.log
import NeutrinoCore
import NeutrinoAuth

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
    /// Items from GET /api/v1/drive/starred.
    @Published private(set) var starredItems: [DriveItem] = []

    @Published var isLoading = false
    @Published var error: String?

    /// Parent IDs (nil = root) whose contents have been fetched from the server at least
    /// once this session. Used to guard `fileWasUploaded` against inserting a lone child
    /// into a folder whose siblings were never loaded (see that method for details).
    ///
    /// Root starts pre-marked as loaded: every reachable upload entry point (the "+" button
    /// in `FilesView`, `UploadSheet`) only appears after the Files tab has loaded root, so in
    /// practice root is always loaded by the time a manual upload can happen. The guard's
    /// real value is for non-root folders — e.g. photo sync's destination folder, which the
    /// user may never have opened.
    private var loadedParentIDs: Set<String?> = [nil]

    // MARK: - Init

    /// `session` is injectable so tests can stub network responses via a custom
    /// `URLProtocol` (e.g. `MockURLProtocol`) without touching production call sites.
    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Test Seeding

    #if DEBUG
    /// Seed state for unit tests — bypasses the network entirely.
    /// Every parentID represented in `myDrive` (plus root, when `myDrive` is non-empty or
    /// explicitly requested) is marked as "loaded" so `fileWasUploaded` behaves the way it
    /// would after the app has actually fetched that folder's contents.
    convenience init(myDrive: [DriveItem] = [], trash: [DriveItem] = [],
                     recents: [DriveItem] = [], shared: [DriveItem] = [],
                     session: URLSession = .shared) {
        self.init(session: session)
        self.allItems   = myDrive
        self.trashItems = trash
        self.recentItems = recents
        self.sharedItems = shared
        self.loadedParentIDs.insert(nil)
        for item in myDrive {
            self.loadedParentIDs.insert(item.parentID)
        }
    }

    /// Marks `parentID` as having been loaded, for tests that need to seed loaded-folder
    /// state without seeding actual child items (e.g. an intentionally empty folder).
    func debugMarkLoaded(parentID: String?) {
        loadedParentIDs.insert(parentID)
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

    /// Injectable so tests can stub network responses; defaults to `.shared` in production.
    private let session: URLSession

    // MARK: - Section Query

    func items(in section: DriveSection, parentID: String?) -> [DriveItem] {
        switch section {
        case .myDrive:  return allItems.filter { $0.parentID == parentID }
        case .recents:  return recentItems
        case .trash:    return trashItems
        case .shared:   return sharedItems
        case .starred:  return starredItems
        }
    }

    // MARK: - Single Item

    /// Fetches one file's metadata straight from the server.
    ///
    /// Everything else in this service reads from a listing, which is enough while the user is
    /// browsing. A Universal Link is not: it names a file that may sit in a folder this session has
    /// never opened, so there is no listing to read it out of.
    func fetchItem(id: String) async throws -> DriveItem {
        let metadata: APIFileMetadataResponse = try await get("/api/v1/drive/files/\(id)/metadata")
        return DriveItem(metadata: metadata)
    }

    // MARK: - Load

    func loadSection(_ section: DriveSection, parentID: String?) async {
        logger.debug("loadSection: \(section.rawValue, privacy: .public) parentID=\(parentID ?? "root", privacy: .public)")
        isLoading = true
        error = nil
        do {
            switch section {
            case .myDrive:
                let response: APIFolderContentsResponse = try await get(
                    folderContentsPath(parentID: parentID)
                )
                let folders = response.folders.map { DriveItem(folder: $0) }
                let files   = response.files.map   { DriveItem(file: $0) }
                // Replace cached items for this parent to avoid stale duplicates.
                allItems.removeAll { $0.parentID == parentID }
                allItems.append(contentsOf: folders)
                allItems.append(contentsOf: files)
                loadedParentIDs.insert(parentID)
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

            case .starred:
                // The server's default limit is 5 — that is a "Quick Access" default, not a
                // favorites list — so an explicit larger limit is always sent.
                let response: APIStarredContentsResponse = try await get(
                    "/api/v1/drive/starred?limit=\(Self.starredFetchLimit)"
                )
                starredItems = response.folders.map { DriveItem(folder: $0) }
                            + response.files.map   { DriveItem(file: $0) }
                logger.debug("loadSection starred: loaded \(response.folders.count) folders, \(response.files.count) files")

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

    // MARK: - Favorites

    /// How many starred items to request. The endpoint defaults to 5, which suits the web
    /// app's "Quick Access" strip but would silently truncate a Favorites list.
    static let starredFetchLimit = 200

    /// Star or unstar an item.
    ///
    /// There is no dedicated star endpoint — it is a field on the ordinary update handler
    /// (`UpdateFileRequest.is_starred` / `UpdateFolderRequest.is_starred`), so this is a
    /// `PATCH` to the item itself with a single key.
    ///
    /// Optimistic with rollback, matching `rename`/`move`. Both `allItems` and `starredItems`
    /// are updated so the Starred section reflects the change immediately without a refetch.
    func setStarred(itemID: String, isStarred: Bool) {
        let previous = item(withID: itemID)
        guard let previous else { return }
        let isFolder = previous.type == .folder
        logger.debug("setStarred: id=\(itemID, privacy: .public) starred=\(isStarred)")

        applyStarred(itemID: itemID, isStarred: isStarred, template: previous)

        Task {
            do {
                if isFolder {
                    let body = APISetStarredRequest(isStarred: isStarred)
                    let _: APIFolderResponse = try await patch("/api/v1/drive/folders/\(itemID)", body: body)
                } else {
                    let body = APISetStarredRequest(isStarred: isStarred)
                    let _: APIFileResponse = try await patch("/api/v1/drive/files/\(itemID)", body: body)
                }
                logger.debug("setStarred succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("setStarred failed: id=\(itemID, privacy: .public) error=\(error, privacy: .public)")
                applyStarred(itemID: itemID, isStarred: !isStarred, template: previous)
                self.error = error.localizedDescription
            }
        }
    }

    func isStarred(itemID: String) -> Bool {
        item(withID: itemID)?.isStarred ?? false
    }

    /// Mirrors a star change into every cached collection.
    ///
    /// `starredItems` is maintained here rather than recomputed from `allItems`, because the
    /// Starred section can contain items whose parent folder has never been loaded — they
    /// would not be in `allItems` at all.
    private func applyStarred(itemID: String, isStarred: Bool, template: DriveItem) {
        for index in allItems.indices where allItems[index].id == itemID {
            allItems[index].isStarred = isStarred
        }
        for index in recentItems.indices where recentItems[index].id == itemID {
            recentItems[index].isStarred = isStarred
        }
        for index in sharedItems.indices where sharedItems[index].id == itemID {
            sharedItems[index].isStarred = isStarred
        }
        if isStarred {
            if !starredItems.contains(where: { $0.id == itemID }) {
                var starred = template
                starred.isStarred = true
                starredItems.append(starred)
            }
        } else {
            starredItems.removeAll { $0.id == itemID }
        }
    }

    /// Finds an item in any cached collection — the star action is reachable from My Drive,
    /// Recents, Shared, and Starred itself.
    private func item(withID itemID: String) -> DriveItem? {
        allItems.first(where: { $0.id == itemID })
            ?? starredItems.first(where: { $0.id == itemID })
            ?? recentItems.first(where: { $0.id == itemID })
            ?? sharedItems.first(where: { $0.id == itemID })
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
    ///
    /// Skips the append when `result.folderId`'s contents have never been loaded from the
    /// server (i.e. `loadSection(.myDrive, parentID:)` has not been called for that folder
    /// this session). Without this guard, a background photo-sync upload into a folder the
    /// user has never opened would insert a lone child whose siblings were never fetched,
    /// and the file browser would render that folder as if it contained only one file.
    func fileWasUploaded(_ result: UploadResult) {
        guard loadedParentIDs.contains(result.folderId) else {
            logger.debug("fileWasUploaded: skipping optimistic append — parent \(result.folderId ?? "root", privacy: .public) not loaded")
            return
        }
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

    // MARK: - Search Indexing

    /// Every file across the whole My Drive tree, fetched fresh via a recursive walk of
    /// `/api/v1/drive` and `/api/v1/drive/folders/{id}`.
    ///
    /// Deliberately independent of `allItems`/`loadedParentIDs`: those reflect only the
    /// folders this session has browsed into, which is not enough to build a complete search
    /// index. This does not touch either — it is a read for `SearchIndexSyncService`'s
    /// periodic full reindex, not a substitute for the lazy per-folder loading the file
    /// browser relies on.
    ///
    /// Returns `nil` if any branch of the walk fails (a transient network error, a
    /// mid-walk sign-out, etc.) rather than the files collected so far. `SearchIndexSyncService`
    /// uses this result to *delete* index entries that are no longer present — treating a
    /// partial walk as if it were the whole tree would make one flaky request look like every
    /// file in that branch was deleted, wrongly pruning entries a sync from another device may
    /// have just pulled in.
    func fetchAllFilesForIndexing() async -> [DriveItem]? {
        await walkForIndexing(parentID: nil)
    }

    private func walkForIndexing(parentID: String?) async -> [DriveItem]? {
        let response: APIFolderContentsResponse
        do {
            response = try await get(folderContentsPath(parentID: parentID))
        } catch {
            logger.error("fetchAllFilesForIndexing: failed at parent=\(parentID ?? "root", privacy: .public) error=\(error, privacy: .public)")
            return nil
        }
        var result = response.files.map { DriveItem(file: $0) }
        for folder in response.folders {
            guard let children = await walkForIndexing(parentID: folder.id) else { return nil }
            result.append(contentsOf: children)
        }
        return result
    }

    // MARK: - Folder Resolution

    /// Find-or-create a folder named `name` under `parentID` (nil = root).
    ///
    /// If a folder with a case-insensitive matching name already exists under `parentID`,
    /// its ID is returned (adopted) rather than creating a duplicate — so a pre-existing
    /// "iPhone photos" is reused instead of producing a second "iPhone Photos" folder.
    func ensureFolder(named name: String, parentID: String?) async throws -> String {
        let response: APIFolderContentsResponse = try await get(folderContentsPath(parentID: parentID))
        if let match = response.folders.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            logger.debug("ensureFolder: adopted existing folder id=\(match.id, privacy: .public) name=\(match.name, privacy: .public)")
            return match.id
        }
        let body = APICreateFolderRequest(name: name, parentId: parentID)
        let created: APIFolderResponse = try await post("/api/v1/drive/folders", body: body)
        logger.debug("ensureFolder: created folder id=\(created.id, privacy: .public) name=\(name, privacy: .public)")
        return created.id
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

    /// The listing path for `parentID`'s contents — or for the drive root when it is nil.
    ///
    /// A user's root folder has no id of its own: the server takes the caller's own user id in its
    /// place. The bare `GET /api/v1/drive` this used to call for the root was folded into
    /// `/drive/folders/{id}` server-side and no longer exists, so a root listing has to name the
    /// user. The id comes off the access token rather than `/api/v1/auth/me`, which spends no round
    /// trip on a claim the server has already signed.
    ///
    /// Not private, so a test can pin the two shapes without a network stub — getting this wrong is
    /// silent, and it browses an empty drive rather than failing loudly.
    func folderContentsPath(parentID: String?) throws -> String {
        if let parentID { return "/api/v1/drive/folders/\(parentID)" }
        guard let rootID = AccessToken.currentUserID() else { throw DriveError.notAuthenticated }
        return "/api/v1/drive/folders/\(rootID)"
    }

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
            (data, response) = try await session.data(for: req)
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
            (data, response) = try await session.data(for: req)
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
            mimeType: nil,
            isStarred: folder.isStarred ?? false
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
            mimeType: file.mimeType,
            isStarred: file.isStarred ?? false
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
    /// Optional so a response that omits the field cannot break folder listing — the star
    /// feature must never be able to take down browsing.
    let isStarred: Bool?
}

private struct APIFileResponse: Decodable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
    let isStarred: Bool?
}

private struct APIStarredContentsResponse: Decodable {
    let files: [APIFileResponse]
    let folders: [APIFolderResponse]
}

private struct APISetStarredRequest: Encodable {
    let isStarred: Bool
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

