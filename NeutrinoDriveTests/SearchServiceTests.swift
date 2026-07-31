import XCTest
@testable import NeutrinoDrive

/// Unit tests for SearchService.
/// Network calls are not made — tests exercise the synchronous/in-process paths only.
///
/// Response decoding (mapping the `/api/v1/drive/search` JSON payload's `items` into
/// `DriveItem`) is NOT covered here. SearchService follows DriveService/DownloadService's
/// convention of a private, file-scoped response DTO + private decoder with no public seam,
/// and this repo's test convention (see DownloadServiceTests.swift) deliberately avoids
/// stubbing URLSession/URLProtocol. That mapping is exercised indirectly via manual/
/// integration testing against the live endpoint. What IS unit-testable without the network —
/// the documented "empty query is a local no-op" behaviour — is covered below.
@MainActor
final class SearchServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeItem(id: String, name: String = "file.txt") -> DriveItem {
        DriveItem(id: id, name: name, type: .file, parentID: nil,
                  size: 1024, modifiedAt: Date(), isTrashed: false, isShared: false,
                  mimeType: "text/plain")
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
}
