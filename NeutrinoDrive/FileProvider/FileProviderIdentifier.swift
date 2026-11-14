import Foundation
import FileProvider

// MARK: - ResolvedIdentifier

/// What an `NSFileProviderItemIdentifier` actually refers to in the Drive.
enum ResolvedIdentifier: Equatable {
    /// `NSFileProviderItemIdentifier.rootContainer` — the Drive root, which has no ID of its
    /// own (it is `parentID == nil` throughout the API).
    case root
    case file(String)
    case folder(String)

    /// The Drive folder ID to enumerate for this identifier, where `nil` means the root.
    /// `nil` overall means "not a container" — a file cannot be enumerated.
    var containerFolderID: String?? {
        switch self {
        case .root:              return .some(nil)
        case .folder(let id):    return .some(id)
        case .file:              return nil
        }
    }
}

// MARK: - FileProviderIdentifier

/// Translation between Drive IDs and `NSFileProviderItemIdentifier`.
///
/// **Why prefixes, and why this is not over-engineering.** `NSFileProviderItemIdentifier` is a
/// single flat string namespace, but Drive file IDs and folder IDs come from two different
/// tables and nothing in the schema guarantees they cannot collide. An unprefixed mapping would
/// fail in the worst possible way: no build error, no request error, just the Files app
/// occasionally fetching a folder's contents for a file — or issuing a delete against the wrong
/// row. Prefixing makes the namespaces disjoint by construction.
///
/// This type lives in the app target as well as the extension target **specifically so it can be
/// unit-tested**. A File Provider extension cannot be instantiated from a test host (see "What
/// is actually testable" in `agent_docs/plans/feature-phase3-ios-ecosystem-integration.md`), so
/// every piece of logic that can be pulled out of the untestable shell is pulled out.
enum FileProviderIdentifier {

    static let filePrefix   = "f:"
    static let folderPrefix = "d:"

    // MARK: - Encode

    static func forFile(_ id: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(filePrefix + id)
    }

    /// A folder identifier, or `.rootContainer` when `id` is nil.
    ///
    /// The root deliberately does **not** get a synthesised ID: the system reserves
    /// `.rootContainer` and an extension that invents its own root identifier gets an empty
    /// location in the Files app.
    static func forFolder(_ id: String?) -> NSFileProviderItemIdentifier {
        guard let id else { return .rootContainer }
        return NSFileProviderItemIdentifier(folderPrefix + id)
    }

    /// The identifier a child with this Drive parent ID should report as its parent.
    static func forParent(_ parentID: String?) -> NSFileProviderItemIdentifier {
        forFolder(parentID)
    }

    // MARK: - Decode

    /// Resolve an identifier back to what it points at.
    ///
    /// Returns `nil` for anything unrecognised rather than guessing. An identifier the system
    /// hands back that we did not mint is a bug somewhere; treating it as a bare Drive ID would
    /// convert that bug into a request against an arbitrary row.
    static func resolve(_ identifier: NSFileProviderItemIdentifier) -> ResolvedIdentifier? {
        if identifier == .rootContainer { return .root }

        let raw = identifier.rawValue
        if raw.hasPrefix(filePrefix) {
            let id = String(raw.dropFirst(filePrefix.count))
            return id.isEmpty ? nil : .file(id)
        }
        if raw.hasPrefix(folderPrefix) {
            let id = String(raw.dropFirst(folderPrefix.count))
            return id.isEmpty ? nil : .folder(id)
        }
        return nil
    }
}
