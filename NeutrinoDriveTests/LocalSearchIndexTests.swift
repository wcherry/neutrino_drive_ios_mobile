import XCTest
@testable import NeutrinoDrive

/// Unit tests for `LocalSearchIndex`. Uses the `#if DEBUG` `seedDocs:seedTokens:` initializer,
/// which bypasses the `.shared` singleton and disk persistence entirely, so these tests never
/// touch real Application Support state.
@MainActor
final class LocalSearchIndexTests: XCTestCase {

    // MARK: - query

    func test_query_findsFileByNamePrefix() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "1", title: "Quarterly Report.pdf", updatedAt: 0, mimeType: "application/pdf", sizeBytes: nil)

        let results = sut.query(text: "quar")

        XCTAssertEqual(results.map(\.documentId), ["1"])
    }

    func test_query_isCaseInsensitive() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "1", title: "Vacation Photo.jpg", updatedAt: 0, mimeType: "image/jpeg", sizeBytes: nil)

        let results = sut.query(text: "VACATION")

        XCTAssertEqual(results.map(\.documentId), ["1"])
    }

    func test_query_requiresEveryTermToMatch() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "1", title: "Budget Report.xlsx", updatedAt: 0, mimeType: nil, sizeBytes: nil)
        sut.upsertFile(id: "2", title: "Budget Notes.txt", updatedAt: 0, mimeType: nil, sizeBytes: nil)

        let results = sut.query(text: "budget report")

        XCTAssertEqual(results.map(\.documentId), ["1"])
    }

    func test_query_dropsPrefixesShorterThanThreeCharacters() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "1", title: "CV.pdf", updatedAt: 0, mimeType: nil, sizeBytes: nil)

        // "cv" is below the minimum prefix length, so it matches nothing rather than
        // everything — mirrors the web engine's MIN_PREFIX_LENGTH.
        XCTAssertTrue(sut.query(text: "cv").isEmpty)
    }

    func test_query_noMatchReturnsEmpty() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "1", title: "Invoice.pdf", updatedAt: 0, mimeType: nil, sizeBytes: nil)

        XCTAssertTrue(sut.query(text: "receipt").isEmpty)
    }

    func test_query_excludesNonFileDocumentTypes() {
        // A doc of a type this app has no view for (e.g. synced from a web client's Notes)
        // must never surface in Drive search results.
        let note = SearchDocEntry(documentId: "n1", type: "note", title: "Meeting Notes",
                                  titleTerms: ["meeting", "notes"], contentTerms: [], updatedAt: 0, mimeType: nil)
        let sut = LocalSearchIndex(seedDocs: [note], seedTokens: [
            SearchTokenEntry(term: "meeting", documentId: "n1", field: "title", frequency: 1, positions: [0]),
        ])

        XCTAssertTrue(sut.query(text: "meeting").isEmpty)
    }

    // MARK: - upsertFile

    func test_upsertFile_returnsTrueOnFirstInsert() {
        let sut = LocalSearchIndex(seedDocs: [])
        XCTAssertTrue(sut.upsertFile(id: "1", title: "a.txt", updatedAt: 0, mimeType: nil, sizeBytes: nil))
    }

    func test_upsertFile_returnsFalseWhenNothingChanged() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "1", title: "a.txt", updatedAt: 100, mimeType: "text/plain", sizeBytes: 10)

        let changed = sut.upsertFile(id: "1", title: "a.txt", updatedAt: 100, mimeType: "text/plain", sizeBytes: 10)

        XCTAssertFalse(changed)
    }

    func test_upsertFile_returnsTrueWhenTitleChanges() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "1", title: "old.txt", updatedAt: 0, mimeType: nil, sizeBytes: nil)

        let changed = sut.upsertFile(id: "1", title: "new.txt", updatedAt: 0, mimeType: nil, sizeBytes: nil)

        XCTAssertTrue(changed)
        XCTAssertEqual(sut.query(text: "new").map(\.documentId), ["1"])
        XCTAssertTrue(sut.query(text: "old").isEmpty)
    }

    // MARK: - removeDocument

    func test_removeDocument_dropsItFromQueryResults() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "1", title: "Deleteme.txt", updatedAt: 0, mimeType: nil, sizeBytes: nil)

        sut.removeDocument(id: "1")

        XCTAssertTrue(sut.query(text: "deleteme").isEmpty)
        XCTAssertEqual(sut.documentCount, 0)
    }

    // MARK: - reconcileFileDocuments

    func test_reconcileFileDocuments_removesFileNotInTheAuthoritativeSet() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "1", title: "Kept.txt", updatedAt: 0, mimeType: nil, sizeBytes: nil)
        sut.upsertFile(id: "2", title: "Trashed.txt", updatedAt: 0, mimeType: nil, sizeBytes: nil)

        let changed = sut.reconcileFileDocuments(with: [
            (id: "1", title: "Kept.txt", updatedAt: 0, mimeType: nil, sizeBytes: nil),
        ])

        XCTAssertTrue(changed)
        XCTAssertEqual(sut.documentCount, 1)
        XCTAssertTrue(sut.query(text: "trashed").isEmpty)
        XCTAssertEqual(sut.query(text: "kept").map(\.documentId), ["1"])
    }

    func test_reconcileFileDocuments_preservesNonFileDocuments() {
        // A reconcile pass is Drive-file-only bookkeeping; entries synced in from another
        // client's document types must survive it untouched.
        let note = SearchDocEntry(documentId: "n1", type: "note", title: "Ideas",
                                  titleTerms: ["ideas"], contentTerms: [], updatedAt: 0, mimeType: nil)
        let sut = LocalSearchIndex(seedDocs: [note])

        _ = sut.reconcileFileDocuments(with: [
            (id: "1", title: "New File.txt", updatedAt: 0, mimeType: nil, sizeBytes: nil),
        ])

        XCTAssertEqual(sut.documentCount, 2)
    }

    func test_reconcileFileDocuments_noChangeReturnsFalse() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "1", title: "Stable.txt", updatedAt: 42, mimeType: "text/plain", sizeBytes: 5)

        let changed = sut.reconcileFileDocuments(with: [
            (id: "1", title: "Stable.txt", updatedAt: 42, mimeType: "text/plain", sizeBytes: 5),
        ])

        XCTAssertFalse(changed)
    }

    // MARK: - Snapshot export / import round trip

    func test_exportSnapshot_thenReplaceAll_roundTripsQueryableState() {
        let source = LocalSearchIndex(seedDocs: [])
        source.upsertFile(id: "1", title: "Roundtrip.pdf", updatedAt: 123, mimeType: "application/pdf", sizeBytes: 99)

        let snapshot = source.exportSnapshot()
        XCTAssertEqual(snapshot.format, SearchIndexSnapshot.currentFormat)

        let destination = LocalSearchIndex(seedDocs: [])
        destination.replaceAll(with: snapshot)

        let results = destination.query(text: "roundtrip")
        XCTAssertEqual(results.map(\.documentId), ["1"])
        XCTAssertEqual(results.first?.sizeBytes, 99)
    }

    func test_replaceAll_dropsWhateverWasThereBefore() {
        let sut = LocalSearchIndex(seedDocs: [])
        sut.upsertFile(id: "old", title: "Old.txt", updatedAt: 0, mimeType: nil, sizeBytes: nil)

        sut.replaceAll(with: SearchIndexSnapshot(format: SearchIndexSnapshot.currentFormat, createdAt: 0, docs: [], tokens: []))

        XCTAssertEqual(sut.documentCount, 0)
    }
}
