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

    // MARK: - Computed

    /// Returns the appropriate SF Symbol name for this item.
    var iconName: String {
        switch type {
        case .folder:
            return "folder.fill"
        case .file:
            guard let mime = mimeType else { return "doc" }
            if mime.hasPrefix("image/")       { return "photo" }
            if mime == "application/pdf"       { return "doc.richtext" }
            if mime.hasPrefix("video/")       { return "film" }
            if mime.hasPrefix("audio/")       { return "music.note" }
            if mime == "application/zip"
                || mime == "application/x-zip-compressed"
                || mime == "application/x-tar"
                || mime == "application/x-gzip" { return "archivebox" }
            if mime.hasPrefix("text/")        { return "doc.text" }
            return "doc"
        }
    }
}
