import XCTest
@testable import NeutrinoDrive

/// Unit tests for `IncomingDocument` — the open-in-place handling.
///
/// The criterion these tests actually protect: **an incoming document the app did not copy is
/// never deleted.** Before Phase 3 the key-import path ended in an unconditional
/// `FileManager.removeItem(at: url)`, which was safe only while
/// `LSSupportsOpeningDocumentsInPlace` was `false`. Now that it is `true`, the same line would
/// delete a user's own file out of iCloud Drive as a side effect of importing a key from it.
final class IncomingDocumentTests: XCTestCase {

    private var container: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("nd-incoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container.appendingPathComponent("Inbox"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
        try super.tearDownWithError()
    }

    private func writeFile(at url: URL, contents: String = "{}") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    // MARK: - Classification

    func test_classify_urlInsideInbox_isInboxCopy() throws {
        let url = container.appendingPathComponent("Inbox/key.json")
        try writeFile(at: url)

        XCTAssertEqual(IncomingDocument.classify(url: url, documentsDirectory: container),
                       .inboxCopy)
    }

    func test_classify_urlOutsideInbox_isInPlace() throws {
        let url = container.appendingPathComponent("Elsewhere/key.json")
        try writeFile(at: url)

        XCTAssertEqual(IncomingDocument.classify(url: url, documentsDirectory: container),
                       .inPlace)
    }

    /// An unrecognised URL — another provider's container, an iCloud Drive path — must fail
    /// **safe**. Being wrong in the "leaks a temp file" direction is acceptable; being wrong in
    /// the "deletes a user's document" direction is not.
    func test_classify_unknownURL_defaultsToInPlace() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/key.json")
        XCTAssertEqual(IncomingDocument.classify(url: url, documentsDirectory: container),
                       .inPlace)
    }

    /// A string-prefix test would classify `…/Documents/InboxNotes/key.json` as an Inbox copy,
    /// and then delete it. Path-component comparison makes that impossible.
    func test_classify_filenameContainingInbox_isNotInboxCopy() throws {
        let url = container.appendingPathComponent("InboxNotes/Inbox.json")
        try writeFile(at: url)

        XCTAssertEqual(IncomingDocument.classify(url: url, documentsDirectory: container),
                       .inPlace)
    }

    func test_classify_nestedInsideInbox_isInboxCopy() throws {
        let url = container.appendingPathComponent("Inbox/sub/key.json")
        try writeFile(at: url)

        XCTAssertEqual(IncomingDocument.classify(url: url, documentsDirectory: container),
                       .inboxCopy)
    }

    /// The Inbox directory itself is not a document inside it.
    func test_isContained_directoryItself_isFalse() {
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        XCTAssertFalse(IncomingDocument.isContained(url: inbox, in: inbox))
    }

    // MARK: - Deletability

    func test_inPlaceDocument_isNotDeletable() {
        XCTAssertFalse(IncomingDocument.Origin.inPlace.isDeletable)
    }

    func test_inboxCopy_isDeletable() {
        XCTAssertTrue(IncomingDocument.Origin.inboxCopy.isDeletable)
    }

    // MARK: - Reading

    func test_read_returnsFileContents() throws {
        let url = container.appendingPathComponent("Elsewhere/key.json")
        try writeFile(at: url, contents: #"{"keyVersion":1}"#)

        let data = try IncomingDocument.read(url: url)

        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"keyVersion":1}"#)
    }

    func test_read_throwsForMissingFile() {
        let url = container.appendingPathComponent("Elsewhere/missing.json")
        XCTAssertThrowsError(try IncomingDocument.read(url: url))
    }

    /// An unbalanced security scope leaks a sandbox extension for the life of the process and
    /// eventually breaks unrelated file opens — a symptom nobody would trace back to key import.
    /// A missing file drives the throwing path; the `defer` is what keeps the scope balanced.
    func test_read_releasesSecurityScope_onThrow() {
        let url = container.appendingPathComponent("Elsewhere/missing.json")

        XCTAssertThrowsError(try IncomingDocument.read(url: url))
        // A second read must behave identically — a leaked scope would change the outcome.
        XCTAssertThrowsError(try IncomingDocument.read(url: url))
    }

    // MARK: - consume

    func test_consume_deletesInboxCopy() throws {
        let url = container.appendingPathComponent("Inbox/key.json")
        try writeFile(at: url)

        _ = try IncomingDocument.consume(url: url, documentsDirectory: container)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "an Inbox copy is ours to clean up")
    }

    /// The headline test of this file.
    func test_consume_leavesInPlaceDocumentOnDisk() throws {
        let url = container.appendingPathComponent("Elsewhere/key.json")
        try writeFile(at: url)

        _ = try IncomingDocument.consume(url: url, documentsDirectory: container)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "an in-place document belongs to the user and must survive import")
    }

    func test_consume_returnsContentsForBothOrigins() throws {
        let inbox = container.appendingPathComponent("Inbox/a.json")
        let inPlace = container.appendingPathComponent("Elsewhere/b.json")
        try writeFile(at: inbox, contents: "A")
        try writeFile(at: inPlace, contents: "B")

        XCTAssertEqual(String(data: try IncomingDocument.consume(url: inbox, documentsDirectory: container),
                              encoding: .utf8), "A")
        XCTAssertEqual(String(data: try IncomingDocument.consume(url: inPlace, documentsDirectory: container),
                              encoding: .utf8), "B")
    }
}
