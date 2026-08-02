import Foundation
import FileProvider
import UniformTypeIdentifiers

// MARK: - FileProviderLimits

enum FileProviderLimits {

    /// The largest ciphertext the File Provider extension will attempt to decrypt.
    ///
    /// `E2EEDownloader` decrypts whole-file in memory — libsodium's secretstream is opened over
    /// one buffer and pulled in a single call — so peak usage is roughly two copies of the file.
    /// An app can absorb that. A File Provider extension's memory budget cannot, and exceeding
    /// it means a jetsam kill, which the Files app surfaces as an uninformative generic failure
    /// with no hint that size was the cause.
    ///
    /// Refusing above this ceiling trades a working feature for an honest error. The real fix is
    /// streaming decryption, which would benefit the app equally and is out of scope here; see
    /// "Materialization and the memory ceiling" in
    /// `agent_docs/plans/feature-phase3-ios-ecosystem-integration.md`.
    static let maxMaterializableBytes: Int64 = 64 * 1024 * 1024

    /// Whether a file of this size may be materialized. An unknown size is permitted — the
    /// real ceiling is enforced again in `E2EEDownloader` against the actual transferred bytes,
    /// which is the only figure that cannot be stale.
    static func canMaterialize(sizeBytes: Int64?) -> Bool {
        guard let sizeBytes else { return true }
        return sizeBytes <= maxMaterializableBytes
    }
}

// MARK: - FileProviderItem

/// A single Drive file or folder, as the system sees it.
///
/// Constructed from the wire records (`DriveFileRecord` / `DriveFolderRecord`) rather than from
/// `DriveItem`, because `DriveItem` is a view model carrying UI state the extension has no use
/// for. Kept as a plain `struct` in the app target as well as the extension target so its
/// mapping is unit-testable — see `FileProviderIdentifier` for why that matters.
final class FileProviderItem: NSObject, NSFileProviderItem {

    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion
    let capabilities: NSFileProviderItemCapabilities

    // MARK: - Init

    init(itemIdentifier: NSFileProviderItemIdentifier,
         parentItemIdentifier: NSFileProviderItemIdentifier,
         filename: String,
         contentType: UTType,
         documentSize: NSNumber?,
         contentModificationDate: Date?,
         capabilities: NSFileProviderItemCapabilities,
         versionToken: String) {
        self.itemIdentifier = itemIdentifier
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = filename
        self.contentType = contentType
        self.documentSize = documentSize
        self.contentModificationDate = contentModificationDate
        self.capabilities = capabilities
        let token = Data(versionToken.utf8)
        self.itemVersion = NSFileProviderItemVersion(contentVersion: token, metadataVersion: token)
    }

    // MARK: - Root

    /// The Drive root. Required: a replicated extension must be able to answer `item(for:)` on
    /// `.rootContainer` before it can enumerate anything.
    static func root() -> FileProviderItem {
        FileProviderItem(
            itemIdentifier: .rootContainer,
            parentItemIdentifier: .rootContainer,
            filename: "Neutrino Drive",
            contentType: .folder,
            documentSize: nil,
            contentModificationDate: nil,
            capabilities: Self.folderCapabilities,
            versionToken: "root"
        )
    }

    // MARK: - From wire records

    convenience init(file: DriveFileRecord) {
        self.init(
            itemIdentifier: FileProviderIdentifier.forFile(file.id),
            parentItemIdentifier: FileProviderIdentifier.forParent(file.folderId),
            filename: file.name,
            contentType: Self.contentType(forMIME: file.mimeType, filename: file.name),
            documentSize: NSNumber(value: file.sizeBytes),
            contentModificationDate: file.updatedAt,
            capabilities: Self.fileCapabilities,
            versionToken: Self.versionToken(id: file.id, date: file.updatedAt)
        )
    }

    convenience init(folder: DriveFolderRecord) {
        self.init(
            itemIdentifier: FileProviderIdentifier.forFolder(folder.id),
            parentItemIdentifier: FileProviderIdentifier.forParent(folder.parentId),
            filename: folder.name,
            contentType: .folder,
            // A folder must not advertise a document size. Reporting one makes the Files app
            // render it as a zero-byte document rather than as a navigable container.
            documentSize: nil,
            contentModificationDate: folder.updatedAt,
            capabilities: Self.folderCapabilities,
            versionToken: Self.versionToken(id: folder.id, date: folder.updatedAt)
        )
    }

    // MARK: - Capabilities

    /// **Reading, renaming, reparenting, deleting — but deliberately not `.allowsWriting`.**
    ///
    /// Allowing in-place writes would have the system call `modifyItem` with new contents, and
    /// there is no endpoint that replaces a file's ciphertext in place: `POST /files/upload`
    /// creates a *new* file record, and `PUT /files/{id}/autosave` is the Neutrino-native
    /// document path, not a general blob replace. Advertising writability we cannot honour would
    /// let a user edit a document in Pages, see it save, and lose the edit — the worst available
    /// outcome. Read-only is the honest capability set until a replace endpoint exists.
    static let fileCapabilities: NSFileProviderItemCapabilities = [
        .allowsReading, .allowsRenaming, .allowsReparenting, .allowsDeleting
    ]

    /// **`.allowsAddingSubItems` and `.allowsWriting` are the same bit** (both raw value `2`);
    /// likewise `.allowsContentEnumerating` and `.allowsReading` (both `1`). The SDK header says
    /// so explicitly — the names are the folder-facing spellings of the file-facing constants,
    /// not distinct permissions.
    ///
    /// So a folder that accepts new files unavoidably reports `.allowsWriting`. That is correct
    /// here — creating items in a folder *is* supported, via `createItem` — but it means the
    /// "never writable" property asserted for files cannot be asserted for folders, and a test
    /// claiming otherwise would be testing an impossibility rather than a decision.
    static let folderCapabilities: NSFileProviderItemCapabilities = [
        .allowsReading, .allowsRenaming, .allowsReparenting, .allowsDeleting,
        .allowsAddingSubItems, .allowsContentEnumerating
    ]

    // MARK: - Helpers

    /// Resolve a UTType from the server's MIME type, falling back to the filename extension and
    /// finally to `.data`.
    ///
    /// Neutrino's own `application/vnd.neutrino.*` types are not registered with the system.
    ///
    /// The subtlety that cost a test: `UTType(mimeType:)` does **not** return nil for an
    /// unregistered MIME type — it synthesises a *dynamic* type (`dyn.a…`). A dynamic type is
    /// useless to the Files app: it conveys nothing, matches no opener, and would shadow the far
    /// better answer available from the filename extension. So declared-ness is checked, not
    /// mere non-nil-ness, and a dynamic result falls through to the extension and finally to
    /// `.data`.
    ///
    /// `.data` is the right terminal answer for a Neutrino-native doc: the Files app should not
    /// claim to know how to open one, because only the app can render it.
    static func contentType(forMIME mimeType: String?, filename: String) -> UTType {
        if let mimeType, let type = UTType(mimeType: mimeType), type.isDeclared { return type }
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.isDeclared { return type }
        return .data
    }

    /// A stable per-revision token.
    ///
    /// `NSFileProviderItemVersion` compares tokens byte-for-byte; it does not interpret them. The
    /// ID is included alongside the timestamp so two items that happen to share a modification
    /// second still version distinctly.
    static func versionToken(id: String, date: Date) -> String {
        "\(id)@\(Int64(date.timeIntervalSince1970 * 1000))"
    }
}
