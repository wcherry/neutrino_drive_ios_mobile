import XCTest
@testable import NeutrinoDrive

/// Unit tests for SearchService.
///
/// Search runs entirely against the on-device `LocalSearchIndex` (see
/// `SearchIndexSyncService` for how that index gets built and kept in sync) — no network call
/// is made, so both the empty-query no-op and real query/result-mapping behaviour are
/// unit-testable by injecting a seeded, non-shared `LocalSearchIndex`.
@MainActor
final class SearchServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeItem(id: String, name: String = "file.txt") -> DriveItem {
        DriveItem(id: id, name: name, type: .file, parentID: nil,
                  size: 1024, modifiedAt: Date(), isTrashed: false, isShared: false,
                  mimeType: "text/plain")
    }

    /// A `LocalSearchIndex` seeded with one file, independent of the `.shared` singleton.
    private func seededIndex(id: String = "1", title: String = "Quarterly Report.pdf",
                             mimeType: String? = "application/pdf") -> LocalSearchIndex {
        let index = LocalSearchIndex(seedDocs: [])
        index.upsertFile(id: id, title: title, updatedAt: 1_700_000_000_000, mimeType: mimeType, sizeBytes: 2048)
        return index
    }

    // MARK: - SearchService initial state

    func test_initialState_resultsIsEmpty() {
        let sut = SearchService()
        XCTAssertTrue(sut.results.isEmpty)
    }

    func test_initialState_isNotSearching() {
        let sut = SearchService()
        XCTAssertFalse(sut.isSearching)
    }

    func test_initialState_errorIsNil() {
        let sut = SearchService()
        XCTAssertNil(sut.error)
    }

    // MARK: - search — empty query is a local no-op (per plan: "Empty search query should
    // clear results (not call the endpoint with q=\"\")")

    func test_search_emptyQuery_clearsExistingResults() async {
        let sut = SearchService()
        sut.results = [makeItem(id: "stale-1"), makeItem(id: "stale-2")]

        await sut.search(query: "")

        XCTAssertTrue(sut.results.isEmpty)
    }

    func test_search_emptyQuery_doesNotSetIsSearching() async {
        let sut = SearchService()

        await sut.search(query: "")

        // An empty query must short-circuit before any network call, so isSearching should
        // never flip true — otherwise the UI would flash a loading spinner for a request
        // that was never sent.
        XCTAssertFalse(sut.isSearching)
    }

    func test_search_emptyQuery_leavesErrorNil() async {
        let sut = SearchService()

        await sut.search(query: "")

        XCTAssertNil(sut.error)
    }

    func test_search_emptyQuery_startingWithNoResults_staysEmpty() async {
        let sut = SearchService()

        await sut.search(query: "")

        XCTAssertTrue(sut.results.isEmpty)
    }

    // MARK: - search — non-empty query, against a seeded local index

    func test_search_matchingQuery_returnsMappedDriveItem() async {
        let sut = SearchService(localIndex: seededIndex())

        await sut.search(query: "quarterly")

        XCTAssertEqual(sut.results.map(\.id), ["1"])
        XCTAssertEqual(sut.results.first?.name, "Quarterly Report.pdf")
        XCTAssertEqual(sut.results.first?.type, .file)
        XCTAssertEqual(sut.results.first?.mimeType, "application/pdf")
        XCTAssertEqual(sut.results.first?.size, 2048)
    }

    func test_search_matchingQuery_leavesIsSearchingFalseAfterCompletion() async {
        let sut = SearchService(localIndex: seededIndex())

        await sut.search(query: "quarterly")

        XCTAssertFalse(sut.isSearching)
    }

    func test_search_nonMatchingQuery_returnsNoResults() async {
        let sut = SearchService(localIndex: seededIndex())

        await sut.search(query: "nonexistent")

        XCTAssertTrue(sut.results.isEmpty)
    }

    func test_search_trimsWhitespaceAroundQuery() async {
        let sut = SearchService(localIndex: seededIndex())

        await sut.search(query: "  quarterly  ")

        XCTAssertEqual(sut.results.map(\.id), ["1"])
    }
}
