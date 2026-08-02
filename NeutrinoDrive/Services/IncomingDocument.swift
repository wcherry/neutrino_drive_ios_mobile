import Foundation
import os.log

// MARK: - IncomingDocument

/// Reads a document handed to the app by another app, correctly, whether or not it was opened
/// **in place**.
///
/// ## The bug this type exists to prevent
///
/// Before Phase 3, `LSSupportsOpeningDocumentsInPlace` was `false`, so iOS copied every incoming
/// document into `<Documents>/Inbox/` and handed over the copy. `RootContentView.onOpenURL`
/// therefore ended with:
///
/// ```swift
/// try? FileManager.default.removeItem(at: url)
/// ```
///
/// which was correct housekeeping for a copy nobody else owned.
///
/// With the flag flipped to `true`, that same URL can be **the user's actual file**, still living
/// in iCloud Drive or another provider. That line would then delete a user's document out of
/// their own storage as a side effect of importing an encryption key from it — silently,
/// unrecoverably, and caused entirely by turning on a flag that appears unrelated. Flipping the
/// flag without this type would have been the single most damaging change in this branch.
///
/// Two further things break at `true`: the URL is security-scoped, so `Data(contentsOf:)` fails
/// without `startAccessingSecurityScopedResource()`; and another process may be writing the file,
/// so the read must be coordinated through `NSFileCoordinator`.
///
/// ## Why classification is by Inbox containment
///
/// The authoritative answer is `UIOpenURLContext.options.openInPlace`, and SwiftUI's `onOpenURL`
/// discards it — it delivers a bare `URL`. Containment in *this app's* Inbox is the available
/// signal, and it is the one that fails in the right direction: anything unrecognised is treated
/// as in-place and therefore **never deleted**. The failure mode is a stale temp file, not a
/// destroyed document. That asymmetry is the entire design.
enum IncomingDocument {

    // MARK: - Classification

    enum Origin: Equatable {
        /// A copy iOS made into this app's Inbox. Ours to delete once consumed.
        case inboxCopy
        /// A document owned by somebody else, opened in place. Read it, never delete it.
        case inPlace

        /// Only an Inbox copy may be removed after import.
        var isDeletable: Bool { self == .inboxCopy }
    }

    /// The app's own Inbox directory — `<Documents>/Inbox`.
    static func inboxDirectory(documentsDirectory: URL? = nil) -> URL? {
        let documents = documentsDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return documents?.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Classify an incoming URL.
    ///
    /// - Parameter documentsDirectory: injectable so tests can classify against a temporary
    ///   container instead of the host app's real one.
    static func classify(url: URL, documentsDirectory: URL? = nil) -> Origin {
        guard let inbox = inboxDirectory(documentsDirectory: documentsDirectory) else {
            return .inPlace
        }
        return isContained(url: url, in: inbox) ? .inboxCopy : .inPlace
    }

    /// Path-component containment, not a string prefix.
    ///
    /// A prefix test would classify `…/Documents/InboxNotes/key.json` as an Inbox copy — and a
    /// file merely *named* `Inbox.json` sitting in the user's iCloud Drive would then be deleted
    /// after import. Comparing standardised path components makes that impossible.
    static func isContained(url: URL, in directory: URL) -> Bool {
        let target = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard candidate.count > target.count else { return false }
        return Array(candidate.prefix(target.count)) == target
    }

    // MARK: - Reading

    /// Read an incoming document's bytes, taking a security scope and coordinating the read.
    ///
    /// The security scope is released in a `defer`, so it is balanced even when the coordinated
    /// read throws. An unbalanced scope leaks a sandbox extension for the life of the process
    /// and eventually causes unrelated file opens to fail — a symptom nobody would connect back
    /// to key import.
    static func read(url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var coordinatorError: NSError?
        var readError: Error?
        var data: Data?

        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
                                       error: &coordinatorError) { readURL in
            do {
                data = try Data(contentsOf: readURL)
            } catch {
                readError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let readError { throw readError }
        guard let data else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }

    /// Read, then clean up **only** if the file was a copy iOS made for us.
    ///
    /// - Returns: the file's bytes.
    static func consume(url: URL, documentsDirectory: URL? = nil) throws -> Data {
        let data = try read(url: url)
        if classify(url: url, documentsDirectory: documentsDirectory).isDeletable {
            try? FileManager.default.removeItem(at: url)
        }
        return data
    }
}
