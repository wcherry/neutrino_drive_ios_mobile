import Foundation

// MARK: - DriveItem

/// Model for a single file or folder in Neutrino Drive.
struct DriveItem: Identifiable, Hashable {

    // MARK: - ItemType

    enum ItemType {
        case folder
        case file
    }

    // MARK: - Properties

    let id: String
    var name: String
    let type: ItemType
    var parentID: String?       // nil = root
    var size: Int64?            // bytes; nil for folders
    var modifiedAt: Date
    var isTrashed: Bool
    var isShared: Bool
    var mimeType: String?       // e.g. "image/jpeg"; nil for folders
    /// Declared last with a default so the synthesised memberwise initialiser stays
    /// source-compatible with every existing call site and test.
    var isStarred: Bool = false

    // MARK: - Computed

    /// What this item is, for icon and tint purposes.
    ///
    /// Derived from the MIME type *and* the filename, so a file the server could only
    /// describe as `application/octet-stream` still gets the icon its extension implies.
    /// See `FileKind.classify`.
    var kind: FileKind {
        FileKind.classify(mimeType: mimeType, filename: name, isFolder: type == .folder)
    }

    var isNeutrinoNativeFormat: Bool {
        kind.isNeutrinoNative
    }

    /// SF Symbol name for this item.
    ///
    /// Note that the Neutrino-native formats are drawn from custom artwork rather than an
    /// SF Symbol — use `FileTypeIcon(kind:)` to render an item, which picks correctly
    /// between the two. This stays for callers that genuinely need a symbol name.
    var iconName: String {
        kind.symbolName
    }
}
