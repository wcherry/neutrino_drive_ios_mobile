import Foundation
import UniformTypeIdentifiers

/// The name a file is uploaded under, given the name its source suggested and the extension
/// its bytes actually have (#49).
///
/// A suggested name often has no extension: Apple Photos suggests `IMG_1234` for what is an
/// `IMG_1234.HEIC`. Uploaded as suggested, the file lands in Drive without one, and everything
/// that reads a type from a name (downloads, previews, search, Live Photo stem pairing) loses
/// it. So the extension of the file actually loaded is added, unless the name already ends in
/// one of the same type.
///
/// One rule for every upload path (the share extension, a Live Photo shared with its motion,
/// the upload sheet's photo picker), so the same photo gets the same name however it arrives.
/// Foundation and UTType only: the share extension compiles it.
enum UploadFileNaming {

    /// - Parameters:
    ///   - suggested: what the source called the item, if anything.
    ///   - fileExtension: the extension of the bytes being uploaded (`heic`, `mov`, `pdf`).
    ///   - loadedFileName: the name the loaded file came with, used when there is no suggestion
    ///     and it looks like a real name rather than a provider's temp name.
    ///   - fallbackStem: a stem for when there is nothing better, e.g. `Shared 20261113_141500`.
    static func name(suggested: String?, fileExtension: String,
                     loadedFileName: String? = nil, fallbackStem: () -> String) -> String {
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = suggested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !trimmed.isEmpty else {
            if let loadedFileName, looksLikeRealName(loadedFileName) {
                return name(suggested: loadedFileName, fileExtension: ext, fallbackStem: fallbackStem)
            }
            let stem = fallbackStem()
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        guard !ext.isEmpty, !hasExtension(trimmed, matching: ext) else { return trimmed }
        return "\(trimmed).\(ext)"
    }

    /// Whether `name` already ends in an extension for the same kind of file as `ext`: the same
    /// extension in any case (`HEIC`/`heic`), a synonym (`jpg`/`jpeg`), or one type conforming to
    /// the other. A dot followed by something the system doesn't know as an extension (`Trip
    /// v1.2`) doesn't count.
    static func hasExtension(_ name: String, matching ext: String) -> Bool {
        let existing = (name as NSString).pathExtension
        guard !existing.isEmpty else { return false }
        if existing.caseInsensitiveCompare(ext) == .orderedSame { return true }
        guard let existingType = UTType(filenameExtension: existing), !existingType.isDynamic,
              let fileType = UTType(filenameExtension: ext), !fileType.isDynamic else { return false }
        return existingType.conforms(to: fileType) || fileType.conforms(to: existingType)
    }

    /// A provider's loaded file is sometimes named after the file, sometimes something opaque
    /// (`version=1&uuid=…&mode=compatible.jpeg`, a bare UUID). Only the former is worth keeping.
    static func looksLikeRealName(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        guard !stem.isEmpty, !stem.contains("="), !stem.contains("&") else { return false }
        return UUID(uuidString: stem) == nil
    }

    /// `Shared 20261113_141500`: dated, so a run of nameless shares doesn't collide.
    static func sharedFallbackStem(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "Shared \(formatter.string(from: date))"
    }
}
