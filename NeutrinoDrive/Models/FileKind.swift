import Foundation

// MARK: - NeutrinoMIME

/// The MIME types the Neutrino server assigns to its own editor documents.
///
/// These are the spellings the backend actually stores (`src/drive/filesystem/dto.rs`,
/// `DriveFileType::mime_types`) and the ones the web client matches on
/// (`web/apps/web/src/lib/file-icons.ts`).
///
/// An earlier `application/vnd.neutrino.*` spelling used here was taken from a Storybook
/// fixture and appears nowhere on the wire — so every native document failed every branch
/// and fell through to the generic file icon. That is the bug this enum exists to prevent
/// recurring: there is now exactly one place to correct if the server ever renames them.
enum NeutrinoMIME {
    static let doc     = "application/x-neutrino-doc"
    static let sheet   = "application/x-neutrino-sheet"
    static let slide   = "application/x-neutrino-slide"
    static let diagram = "application/x-neutrino-diagram"
    static let drawing = "application/x-neutrino-drawing"
    static let note    = "application/x-neutrino-note"

    /// Shared prefix, for "is this ours at all?" checks that must not enumerate the cases.
    static let prefix = "application/x-neutrino-"
}

// MARK: - FileKind

/// What a drive item *is*, for presentation purposes — the one classification the icon,
/// its tint, and the accessibility label all derive from.
///
/// Deliberately richer than the MIME type: it folds the server's MIME, the filename
/// extension, and the folder/file distinction into a single answer, so callers never have
/// to re-derive "is this an image?" from three different inputs and disagree.
enum FileKind: String, CaseIterable {

    case folder

    // Neutrino native editor documents — rendered with the custom icons in
    // Assets.xcassets/FileIcons, not with SF Symbols.
    case neutrinoDoc
    case neutrinoSheet
    case neutrinoSlide
    case neutrinoDiagram
    case neutrinoDrawing
    case neutrinoNote

    // Ordinary files.
    case image
    case video
    case audio
    case pdf
    case spreadsheet
    case presentation
    case document
    case code
    case json
    case archive
    case text
    case unknown

    // MARK: - Classification

    /// Classifies an item from everything known about it.
    ///
    /// MIME wins when it says something useful; the filename extension is consulted when it
    /// does not. That fallback is not theoretical: `UploadService` sends
    /// `application/octet-stream` whenever `UTType` cannot resolve a type for the source
    /// file, and the server stores what it is sent — so a perfectly ordinary `.psd` or `.epub`
    /// can arrive back with a MIME type that classifies nothing.
    static func classify(mimeType: String?, filename: String, isFolder: Bool) -> FileKind {
        if isFolder { return .folder }

        let mime = normalizedMIME(mimeType)

        if let kind = kindForMIME(mime) { return kind }

        let ext = (filename as NSString).pathExtension.lowercased()
        if let kind = extensionKinds[ext] { return kind }

        return .unknown
    }

    /// Lowercased, whitespace-trimmed, with any parameters stripped —
    /// `"Text/HTML; charset=utf-8"` becomes `"text/html"`.
    private static func normalizedMIME(_ mimeType: String?) -> String {
        guard let mimeType else { return "" }
        let base = mimeType.split(separator: ";").first.map(String.init) ?? mimeType
        return base.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Returns nil when the MIME type is absent, generic, or simply unrecognised, so the
    /// caller can fall back to the filename extension.
    private static func kindForMIME(_ mime: String) -> FileKind? {
        guard !mime.isEmpty, !genericMIMEs.contains(mime) else { return nil }

        // Neutrino native types first: they are `application/*` and would otherwise be
        // shadowed by one of the substring checks below.
        switch mime {
        case NeutrinoMIME.doc:     return .neutrinoDoc
        case NeutrinoMIME.sheet:   return .neutrinoSheet
        case NeutrinoMIME.slide:   return .neutrinoSlide
        case NeutrinoMIME.diagram: return .neutrinoDiagram
        case NeutrinoMIME.drawing: return .neutrinoDrawing
        case NeutrinoMIME.note:    return .neutrinoNote
        default: break
        }
        // An unrecognised `x-neutrino-*` type is still one of ours — better a Doc icon than
        // a blank sheet of paper if the server adds a seventh editor before this app ships.
        if mime.hasPrefix(NeutrinoMIME.prefix) { return .neutrinoDoc }

        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }

        if mime == "application/pdf" { return .pdf }
        if mime == "application/json" || mime == "text/json" { return .json }

        if mime.contains("spreadsheet") || mime.contains("excel") || mime == "text/csv" {
            return .spreadsheet
        }
        if mime.contains("presentation") || mime.contains("powerpoint") {
            return .presentation
        }
        if mime.contains("wordprocessing") || mime == "application/msword"
            || mime.contains("opendocument.text") || mime == "application/rtf" {
            return .document
        }
        if archiveMIMEFragments.contains(where: mime.contains) { return .archive }

        if codeMIMEFragments.contains(where: mime.contains) { return .code }
        if mime.hasPrefix("text/") { return .text }

        return nil
    }

    /// MIME types that carry no information — treated as "unknown", so the filename
    /// extension gets its turn.
    private static let genericMIMEs: Set<String> = [
        "application/octet-stream",
        "binary/octet-stream",
        "application/x-binary",
        "application/unknown",
        "content/unknown",
    ]

    private static let archiveMIMEFragments = [
        "zip", "tar", "rar", "gzip", "bzip", "7z", "compressed",
    ]

    private static let codeMIMEFragments = [
        "javascript", "typescript", "python", "ruby", "java", "php", "x-sh",
        "x-go", "rust", "text/css", "text/html", "xml", "x-c", "swift", "yaml",
    ]

    private static let extensionKinds: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        let groups: [(FileKind, [String])] = [
            (.image, ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp",
                      "tiff", "tif", "svg", "avif", "ico", "psd"]),
            (.video, ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp"]),
            (.audio, ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "aiff", "aif", "wma"]),
            (.pdf, ["pdf"]),
            (.spreadsheet, ["xls", "xlsx", "xlsm", "csv", "tsv", "ods", "numbers"]),
            (.presentation, ["ppt", "pptx", "odp", "key"]),
            (.document, ["doc", "docx", "odt", "rtf", "pages", "epub"]),
            (.json, ["json", "jsonl", "geojson"]),
            (.code, ["js", "jsx", "mjs", "cjs", "ts", "tsx", "py", "rb", "java", "kt",
                     "swift", "go", "rs", "c", "h", "cc", "cpp", "hpp", "cs", "m", "mm",
                     "php", "sh", "bash", "zsh", "html", "htm", "css", "scss", "sass",
                     "xml", "yml", "yaml", "toml", "sql", "gradle", "plist"]),
            (.archive, ["zip", "tar", "gz", "tgz", "bz2", "rar", "7z", "xz", "dmg"]),
            (.text, ["txt", "md", "markdown", "rst", "log", "text"]),
        ]
        for (kind, extensions) in groups {
            for ext in extensions { map[ext] = kind }
        }
        return map
    }()

    // MARK: - Presentation

    /// True for the six Neutrino editor formats, which have no downloadable blob — the
    /// server answers their download endpoint with 409 NO_CONTENT, so they must open in the
    /// in-app web viewer rather than through `DownloadService`.
    var isNeutrinoNative: Bool {
        switch self {
        case .neutrinoDoc, .neutrinoSheet, .neutrinoSlide,
             .neutrinoDiagram, .neutrinoDrawing, .neutrinoNote:
            return true
        default:
            return false
        }
    }

    /// The custom Neutrino icon in `Assets.xcassets/FileIcons`, or nil for kinds that use an
    /// SF Symbol. Exactly the Neutrino-native kinds have one.
    var assetName: String? {
        switch self {
        case .neutrinoDoc:     return "FileIconDoc"
        case .neutrinoSheet:   return "FileIconSheet"
        case .neutrinoSlide:   return "FileIconSlide"
        case .neutrinoDiagram: return "FileIconDiagram"
        case .neutrinoDrawing: return "FileIconDrawing"
        case .neutrinoNote:    return "FileIconNote"
        default:               return nil
        }
    }

    /// SF Symbol for this kind. Also the fallback for the Neutrino kinds, used if a custom
    /// asset ever fails to load — every name here exists on iOS 16, the deployment target.
    var symbolName: String {
        switch self {
        case .folder:          return "folder.fill"
        case .neutrinoDoc:     return "doc.text.fill"
        case .neutrinoSheet:   return "tablecells.fill"
        case .neutrinoSlide:   return "rectangle.stack.fill"
        case .neutrinoDiagram: return "point.3.connected.trianglepath.dotted"
        case .neutrinoDrawing: return "paintpalette.fill"
        case .neutrinoNote:    return "note.text"
        case .image:           return "photo.fill"
        case .video:           return "film.fill"
        case .audio:           return "music.note"
        case .pdf:             return "doc.richtext.fill"
        case .spreadsheet:     return "tablecells.fill"
        case .presentation:    return "rectangle.stack.fill"
        case .document:        return "doc.text.fill"
        case .code:            return "chevron.left.forwardslash.chevron.right"
        case .json:            return "curlybraces"
        case .archive:         return "archivebox.fill"
        case .text:            return "doc.plaintext.fill"
        case .unknown:         return "doc.fill"
        }
    }

    /// Spoken description of the type, for the row's accessibility label. VoiceOver users
    /// get nothing from an icon, so the classification has to reach them as words.
    var accessibilityDescription: String {
        switch self {
        case .folder:          return "Folder"
        case .neutrinoDoc:     return "Neutrino Doc"
        case .neutrinoSheet:   return "Neutrino Sheet"
        case .neutrinoSlide:   return "Neutrino Slides"
        case .neutrinoDiagram: return "Neutrino Diagram"
        case .neutrinoDrawing: return "Neutrino Drawing"
        case .neutrinoNote:    return "Neutrino Note"
        case .image:           return "Image"
        case .video:           return "Video"
        case .audio:           return "Audio"
        case .pdf:             return "PDF"
        case .spreadsheet:     return "Spreadsheet"
        case .presentation:    return "Presentation"
        case .document:        return "Document"
        case .code:            return "Code"
        case .json:            return "JSON"
        case .archive:         return "Archive"
        case .text:            return "Text"
        case .unknown:         return "File"
        }
    }
}
