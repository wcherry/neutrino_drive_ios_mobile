import Foundation
import FileProvider
import os.log

// MARK: - FileProviderEnumerator

/// Enumerates one container — the root, a folder, or the working set.
///
/// ## The sync anchor problem
///
/// `NSFileProviderReplicatedExtension` is designed around an incremental delta feed:
/// `currentSyncAnchor` hands the system a cursor, and `enumerateChanges(for:from:)` reports
/// what changed since. **The Neutrino backend has no such endpoint** — no changes route, no
/// cursor, no `updatedSince` query. That was confirmed against the route list in
/// `src/drive/filesystem/api.rs` and `src/drive/storage/api.rs`, not assumed.
///
/// Three responses were possible, and the choice matters more than it looks:
///
/// 1. Fabricate a delta by diffing successive full enumerations. Requires persisting a snapshot
///    of the whole tree inside the extension — user metadata at rest, outside the Keychain,
///    which is the mirror the replicated model exists to avoid. Rejected.
/// 2. Return a constant anchor and report no changes. The system would believe it is up to date
///    forever and serve stale content indefinitely. **This is the option that looks like it
///    works**, which is exactly what makes it the worst one. Rejected.
/// 3. Expire the anchor, forcing a full re-enumeration.
///
/// (3) is implemented. `NSFileProviderError.syncAnchorExpired` is defined by the system's own
/// contract as "drop your cache and enumerate from scratch", so this is the extension telling
/// the truth — it genuinely cannot describe what changed.
///
/// The cost is not hidden: **there is no push and no background sync.** Remote edits appear when
/// the Files app re-enumerates, typically on navigating into a folder or pulling to refresh.
/// Closing that gap needs a backend change feed and cannot be done from the client.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private let container: ResolvedIdentifier
    private let client: DriveAPIClient
    private let logger = Logger(subsystem: "com.neutrino.drive.fileprovider", category: "Enumerator")

    /// How many recent files back the working set — the container the system consults for
    /// spotlight-in-Files, the Recents tab, and favourites.
    private static let workingSetLimit = 100

    /// `nil` container means the working set.
    private let isWorkingSet: Bool

    init(container: ResolvedIdentifier, client: DriveAPIClient) {
        self.container = container
        self.client = client
        self.isWorkingSet = false
        super.init()
    }

    init(workingSetWith client: DriveAPIClient) {
        self.container = .root
        self.client = client
        self.isWorkingSet = true
        super.init()
    }

    func invalidate() {}

    // MARK: - Enumerate items

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        Task {
            do {
                let items = try await fetchItems()
                observer.didEnumerate(items)
                // No pagination: the drive endpoints return a folder's contents in one response,
                // so there is never a second page to advertise.
                observer.finishEnumerating(upTo: nil)
            } catch {
                self.logger.error("enumerateItems failed: \(error, privacy: .public)")
                observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
            }
        }
    }

    private func fetchItems() async throws -> [NSFileProviderItem] {
        if isWorkingSet {
            let files = try await client.recentFiles(limit: Self.workingSetLimit)
            return files.map { FileProviderItem(file: $0) }
        }
        guard let folderID = container.containerFolderID else {
            // A file is not a container. The system should never ask, but answering with an
            // empty list would present a file as an empty folder.
            throw NSFileProviderError(.noSuchItem)
        }
        let contents = try await client.listFolder(folderID: folderID)
        return contents.folders.map { FileProviderItem(folder: $0) }
             + contents.files.map   { FileProviderItem(file: $0) }
    }

    // MARK: - Enumerate changes

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        // See the type documentation. There is no delta feed to consult, so the only honest
        // answer is "your cursor is no longer usable, re-enumerate".
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // A fresh anchor each time, which combines with `syncAnchorExpired` above to mean
        // "always re-enumerate". Deliberately not a constant: a stable anchor would let the
        // system conclude nothing has changed.
        let token = "\(Date().timeIntervalSince1970)"
        completionHandler(NSFileProviderSyncAnchor(Data(token.utf8)))
    }
}

// MARK: - FileProviderErrorMapper

/// Translates the client's errors into the ones the Files app knows how to present.
///
/// Without this, every failure reaches the user as a generic "operation failed". The two that
/// matter are `notAuthenticated` — which makes the Files app offer a sign-in affordance rather
/// than implying the server is broken — and `noSuchItem`, which makes it drop a stale row
/// instead of retrying it forever.
enum FileProviderErrorMapper {

    static func map(_ error: Error) -> Error {
        if let apiError = error as? DriveAPIError {
            switch apiError {
            case .notAuthenticated:  return NSFileProviderError(.notAuthenticated)
            case .notFound:          return NSFileProviderError(.noSuchItem)
            case .serverError, .networkError, .decodingError:
                return NSFileProviderError(.serverUnreachable)
            }
        }
        if let downloadError = error as? DownloadError {
            switch downloadError {
            case .notAuthenticated, .noEncryptionKey:
                return NSFileProviderError(.notAuthenticated)
            case .tooLargeToDecrypt:
                // Surfaced with its own message rather than a File Provider code, because none
                // of them means "too big for this process" and a wrong code would send the user
                // looking in the wrong place. `DownloadError` already carries readable copy.
                return downloadError
            default:
                return NSFileProviderError(.serverUnreachable)
            }
        }
        return error
    }
}
