import Foundation
import FileProvider
import UniformTypeIdentifiers
import os.log

// MARK: - FileProviderExtension

/// Makes Neutrino Drive a location in the iOS Files app, and a source in every document picker
/// (Pages, Numbers, Word, Excel, and any third-party app that presents one).
///
/// ## Why `NSFileProviderReplicatedExtension`
///
/// The deprecated `NSFileProviderExtension` works by materialising placeholder files into a
/// directory the extension owns inside the App Group container — effectively a second copy of
/// the user's tree on disk, outside the Keychain-guarded path. Declining that is a security
/// decision as much as a modernity one. The replicated API (iOS 16+, and this project's floor is
/// exactly iOS 16.0) lets the system own the replica and calls back for content on demand.
///
/// ## E2EE
///
/// Materialization runs `E2EEDownloader` — literally the same source file the app compiles, not
/// a reimplementation — so a file opened from the Files app is decrypted by the same code that
/// decrypts it in the app. Creation runs `E2EEUploader`, so a document saved into Neutrino Drive
/// from Pages is sealed exactly as an in-app upload is. Anything less would punch a silent
/// plaintext hole through the product's central promise. The Keychain reads work because this
/// target carries the same shared access group as the app and the share extension.
///
/// ## What this extension deliberately does not do
///
/// - **No token refresh.** `AuthService` is not compiled in. A 401 becomes
///   `NSFileProviderError.notAuthenticated` and the user resolves it by opening the app. Two
///   processes racing over one refresh token would invalidate the app's session as well.
/// - **No thumbnails.** `fetchThumbnails` would mean decrypting content, rendering a preview,
///   and handing that preview to a system cache — plaintext derived from E2EE content crossing
///   out of the boundary. Not implemented, deliberately.
/// - **No in-place editing.** See `FileProviderItem.fileCapabilities`; there is no endpoint that
///   replaces a file's ciphertext, so writability is not advertised.
/// - **No incremental sync.** See `FileProviderEnumerator` — the backend has no change feed.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain
    private let client: DriveAPIClient
    private let downloader: E2EEDownloader
    private let uploader: E2EEUploader
    private let logger = Logger(subsystem: "com.neutrino.drive.fileprovider", category: "Extension")

    // MARK: - Init

    required init(domain: NSFileProviderDomain) {
        self.domain = domain

        // A **foreground** session, never the shared background one.
        //
        // `BackgroundTransferService` documents "one session per identifier per process", and
        // this is a different process from the app: constructing a second `.background` session
        // with `com.neutrino.drive.transfers` here is undefined behaviour. It is also pointless —
        // an extension is torn down as soon as its operation completes, so it has nothing to
        // hand a background transfer to.
        let transfers = BackgroundTransferService(session: URLSession(configuration: .default))

        self.client = DriveAPIClient(session: URLSession(configuration: .default))
        self.downloader = E2EEDownloader(
            transferService: transfers,
            maxDecryptBytes: FileProviderLimits.maxMaterializableBytes
        )
        self.uploader = E2EEUploader(transferService: transfers)
        super.init()
    }

    func invalidate() {}

    // MARK: - item(for:)

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        guard let resolved = FileProviderIdentifier.resolve(identifier) else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        Task {
            do {
                let item = try await self.resolveItem(resolved)
                completionHandler(item, nil)
            } catch {
                self.logger.error("item(for:) failed: \(error, privacy: .public)")
                completionHandler(nil, FileProviderErrorMapper.map(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    private func resolveItem(_ resolved: ResolvedIdentifier) async throws -> NSFileProviderItem {
        switch resolved {
        case .root:
            return FileProviderItem.root()

        case .file(let id):
            return FileProviderItem(file: try await client.fileMetadata(fileID: id))

        case .folder(let id):
            // There is no `GET /folders/{id}/metadata`. The contents response carries the
            // folder's own record (`FolderContentsResponse.folder`), which is what makes this
            // answerable at all — see the note on `DriveFolderContents`.
            let contents = try await client.listFolder(folderID: id)
            guard let record = contents.folder else { throw NSFileProviderError(.noSuchItem) }
            return FileProviderItem(folder: record)
        }
    }

    // MARK: - fetchContents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        guard let resolved = FileProviderIdentifier.resolve(itemIdentifier),
              case .file(let fileID) = resolved else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        Task {
            do {
                let record = try await self.client.fileMetadata(fileID: fileID)

                // Checked here on the advertised size so an oversized file fails fast with a
                // readable message, and again inside `E2EEDownloader` against the real
                // transferred bytes — the only figure that cannot be stale.
                guard FileProviderLimits.canMaterialize(sizeBytes: record.sizeBytes) else {
                    throw DownloadError.tooLargeToDecrypt(
                        sizeBytes: record.sizeBytes,
                        limitBytes: FileProviderLimits.maxMaterializableBytes
                    )
                }

                let url = try await self.downloader.download(
                    fileID: fileID,
                    fileName: record.name,
                    progress: { fraction in
                        progress.completedUnitCount = Int64(fraction * 100)
                    }
                )
                completionHandler(url, FileProviderItem(file: record), nil)
            } catch {
                self.logger.error("fetchContents failed: \(error, privacy: .public)")
                completionHandler(nil, nil, FileProviderErrorMapper.map(error))
            }
        }
        return progress
    }

    // MARK: - createItem

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        let parentResolved = FileProviderIdentifier.resolve(itemTemplate.parentItemIdentifier)
        guard let parentFolderID = parentResolved?.containerFolderID else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        let isFolder = itemTemplate.contentType == .folder
        let filename = itemTemplate.filename

        Task {
            do {
                if isFolder {
                    let created = try await self.client.createFolder(name: filename,
                                                                     parentID: parentFolderID)
                    completionHandler(FileProviderItem(folder: created), [], false, nil)
                    return
                }

                guard let url else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }

                // Security-scoped: the contents URL belongs to the system's replica, not to us.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let data = try Data(contentsOf: url)

                guard FileProviderLimits.canMaterialize(sizeBytes: Int64(data.count)) else {
                    throw DownloadError.tooLargeToDecrypt(
                        sizeBytes: Int64(data.count),
                        limitBytes: FileProviderLimits.maxMaterializableBytes
                    )
                }

                let mimeType = FileProviderExtension.mimeType(for: itemTemplate, filename: filename)

                // The same encrypt-and-POST the app and the share extension run. A file saved
                // here from Pages is sealed with the user's DEK exactly as an in-app upload is.
                let result = try await self.uploader.upload(
                    data: data,
                    fileName: filename,
                    mimeType: mimeType,
                    parentFolderID: parentFolderID,
                    progress: { fraction in
                        progress.completedUnitCount = Int64(fraction * 100)
                    }
                )

                let record = DriveFileRecord(
                    id: result.id, name: result.name, folderId: result.folderId,
                    sizeBytes: result.sizeBytes, mimeType: result.mimeType,
                    updatedAt: result.updatedAt, isStarred: false
                )
                completionHandler(FileProviderItem(file: record), [], false, nil)
            } catch {
                self.logger.error("createItem failed: \(error, privacy: .public)")
                completionHandler(nil, [], false, FileProviderErrorMapper.map(error))
            }
        }
        return progress
    }

    // MARK: - modifyItem

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        guard let resolved = FileProviderIdentifier.resolve(item.itemIdentifier) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        // Content changes are not supported and are never requested, because
        // `FileProviderItem.fileCapabilities` omits `.allowsWriting`. Reported back as an
        // unapplied field rather than silently swallowed, so the system does not believe an
        // edit landed. See that property for why writability is not advertised.
        let unappliedFields: NSFileProviderItemFields = changedFields.contains(.contents)
            ? [.contents] : []

        let newName = changedFields.contains(.filename) ? item.filename : nil
        let newParent: FolderIDChange
        if changedFields.contains(.parentItemIdentifier),
           let parentResolved = FileProviderIdentifier.resolve(item.parentItemIdentifier),
           let folderID = parentResolved.containerFolderID {
            newParent = .moveTo(folderID)
        } else {
            newParent = .unchanged
        }

        guard newName != nil || newParent != .unchanged else {
            // Nothing we can act on. Hand the item back unchanged rather than issuing a PATCH
            // with an empty body.
            completionHandler(item, unappliedFields, false, nil)
            return progress
        }

        Task {
            do {
                switch resolved {
                case .file(let id):
                    let updated = try await self.client.updateFile(fileID: id, name: newName,
                                                                   folderID: newParent)
                    completionHandler(FileProviderItem(file: updated), unappliedFields, false, nil)
                case .folder(let id):
                    let updated = try await self.client.updateFolder(folderID: id, name: newName,
                                                                     parentID: newParent)
                    completionHandler(FileProviderItem(folder: updated), unappliedFields, false, nil)
                case .root:
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                }
            } catch {
                self.logger.error("modifyItem failed: \(error, privacy: .public)")
                completionHandler(nil, [], false, FileProviderErrorMapper.map(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    // MARK: - deleteItem

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        guard let resolved = FileProviderIdentifier.resolve(identifier) else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return progress
        }

        Task {
            do {
                // Trash, not permanent delete — see `DriveAPIClient.trash`. The Files app says
                // "Delete"; a mis-swipe there must stay recoverable.
                switch resolved {
                case .file(let id):    try await self.client.trash(fileIDs: [id], folderIDs: [])
                case .folder(let id):  try await self.client.trash(fileIDs: [], folderIDs: [id])
                case .root:            throw NSFileProviderError(.noSuchItem)
                }
                completionHandler(nil)
            } catch {
                self.logger.error("deleteItem failed: \(error, privacy: .public)")
                completionHandler(FileProviderErrorMapper.map(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    // MARK: - enumerator

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet {
            return FileProviderEnumerator(workingSetWith: client)
        }
        guard let resolved = FileProviderIdentifier.resolve(containerItemIdentifier),
              resolved.containerFolderID != nil else {
            throw NSFileProviderError(.noSuchItem)
        }
        return FileProviderEnumerator(container: resolved, client: client)
    }

    // MARK: - Helpers

    /// The plaintext MIME type to record for a newly created file.
    ///
    /// The plaintext type matters: the server stores it as the file's `mimeType` and every
    /// client uses it to decide how to render the *decrypted* bytes. Recording the ciphertext's
    /// type instead is the bug fixed in commit `3e89a3e` and it is easy to reintroduce here.
    static func mimeType(for item: NSFileProviderItem, filename: String) -> String {
        if let type = item.contentType, let mime = type.preferredMIMEType {
            return mime
        }
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
