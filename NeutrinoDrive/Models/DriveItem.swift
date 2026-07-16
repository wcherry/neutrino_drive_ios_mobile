import Foundation

// MARK: - DriveItem

/// Model for a single file or folder in Neutrino Drive.
struct DriveItem: Identifiable, Hashable {

    // MARK: - ItemType

    enum ItemType {
        case folder
        case file
    }

    // MARK: - Neutrino Native MIME Types

    enum NeutrinoMIME {
        static let doc      = "application/vnd.neutrino.doc"
        static let sheet    = "application/vnd.neutrino.sheet"
        static let slide    = "application/vnd.neutrino.slide"
        static let diagram  = "application/vnd.neutrino.diagram"
        static let drawing  = "application/vnd.neutrino.drawing"
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

    var isNeutrinoNativeFormat: Bool {
        guard let mime = mimeType else { return false }
        return mime.hasPrefix("application/vnd.neutrino.")
    }

    /// Returns the appropriate SF Symbol name for this item.
    var iconName: String {
        switch type {
        case .folder:
            return "folder.fill"
        case .file:
            guard let mime = mimeType else { return "doc" }
            if mime == NeutrinoMIME.doc      { return "doc.text.fill" }
            if mime == NeutrinoMIME.sheet    { return "tablecells" }
            if mime == NeutrinoMIME.slide    { return "rectangle.stack.fill" }
            if mime == NeutrinoMIME.diagram  { return "flowchart" }
            if mime == NeutrinoMIME.drawing  { return "paintbrush.fill" }
            if mime.hasPrefix("image/")      { return "photo" }
            if mime == "application/pdf"     { return "doc.richtext" }
            if mime.hasPrefix("video/")      { return "film" }
            if mime.hasPrefix("audio/")      { return "music.note" }
            if mime == "application/zip"
                || mime == "application/x-zip-compressed"
                || mime == "application/x-tar"
                || mime == "application/x-gzip" { return "archivebox" }
            if mime.hasPrefix("text/")       { return "doc.text" }
            return "doc"
        }
    }
}
