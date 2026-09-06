import Foundation
import NeutrinoCore

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
    /// Declared last with a default so the synthesised memberwise initialiser stays
    /// source-compatible with every existing call site and test.
    var isStarred: Bool = false

    // MARK: - Computed

    /// The Neutrino app that owns this file's format, or nil for an ordinary upload.
    var neutrinoKind: NeutrinoAppLink.Kind? {
        NeutrinoAppLink.kind(forMIME: mimeType)
    }

    /// True for files Neutrino edits itself, in any of the formats it has stored them in.
    ///
    /// Asks the routing table rather than matching a prefix. `application/vnd.neutrino.` is the
    /// oldest of three spellings; the backend writes `application/x-neutrino-*` and, for Docs,
    /// Sheets, and Slides, a real `.docx`/`.xlsx`/`.pptx` — so a prefix test answered false for
    /// nearly every native file the server creates today, sending each one down the download path
    /// instead of into the viewer that can open it.
    var isNeutrinoNativeFormat: Bool {
        neutrinoKind != nil
    }

    /// Returns the appropriate SF Symbol name for this item.
    var iconName: String {
        switch type {
        case .folder:
            return "folder.fill"
        case .file:
            guard let mime = mimeType else { return "doc" }
            if let kind = neutrinoKind, let symbol = Self.symbolName(for: kind) { return symbol }
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

    /// The SF Symbol for a Neutrino-owned format, or nil to fall through to the generic rules.
    ///
    /// Keyed on the app rather than the mime type so a `.docx` and the legacy `x-neutrino-doc`
    /// beside it in the same folder show the same icon — they are both documents, and which
    /// vintage of the server wrote them is not something a user should be able to see.
    private static func symbolName(for kind: NeutrinoAppLink.Kind) -> String? {
        switch kind {
        case .doc:              return "doc.text.fill"
        case .sheet:            return "tablecells"
        case .slide:            return "rectangle.stack.fill"
        case .diagram:          return "flowchart"
        case .drawing:          return "paintbrush.fill"
        // Notes have never had an icon of their own here, and `.file` is not a format.
        case .note, .file:      return nil
        }
    }
}
