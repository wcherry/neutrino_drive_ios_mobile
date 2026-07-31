import XCTest
@testable import NeutrinoDrive

/// Unit tests for the Phase 5 Favorites feature on `DriveService`.
///
/// Kept in its own file rather than appended to `DriveServiceTests` so the favorites surface —
/// which spans a published collection, an optimistic mutation, and a section query — is legible
/// as one unit.
@MainActor
final class FavoritesTests: XCTestCase {

    // MARK: - Fixtures

    private func makeFile(id: String, name: String = "File", parentID: String? = nil,
                          isStarred: Bool = false) -> DriveItem {
        DriveItem(id: id, name: name, type: .file, parentID: parentID, size: 512,
                  modifiedAt: Date(), isTrashed: false, isShared: false,
                  mimeType: "text/plain", isStarred: isStarred)
    }

    private func makeFolder(id: String, name: String = "Folder",
                            isStarred: Bool = false) -> DriveItem {
        DriveItem(id: id, name: name, type: .folder, parentID: nil, size: nil,
                  modifiedAt: Date(), isTrashed: false, isShared: false,
                  mimeType: nil, isStarred: isStarred)
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    override func setUp() {
        super.setUp()
        KeychainService.save("test-token", forKey: AuthService.accessTokenKey)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        super.tearDown()
    }

    // MARK: - Optimistic toggle

    func test_setStarred_marksItemStarredImmediately() {
        let sut = DriveService(myDrive: [makeFile(id: "f1")])
        sut.setStarred(itemID: "f1", isStarred: true)

        XCTAssertTrue(sut.allItems.first(where: { $0.id == "f1" })?.isStarred == true)
    }

    func test_setStarred_addsItemToStarredSectionImmediately() {
        let sut = DriveService(myDrive: [makeFile(id: "f1", name: "Notes")])
        sut.setStarred(itemID: "f1", isStarred: true)

        XCTAssertEqual(sut.items(in: .starred, parentID: nil).map(\.id), ["f1"])
    }

    func test_setStarred_false_removesItemFromStarredSection() {
        let sut = DriveService(myDrive: [makeFile(id: "f1", isStarred: true)])
        sut.setStarred(itemID: "f1", isStarred: true)
        XCTAssertFalse(sut.items(in: .starred, parentID: nil).isEmpty)

        sut.setStarred(itemID: "f1", isStarred: false)
        XCTAssertTrue(sut.items(in: .starred, parentID: nil).isEmpty)
    }

    func test_setStarred_doesNotDuplicateWhenCalledTwice() {
        let sut = DriveService(myDrive: [makeFile(id: "f1")])
        sut.setStarred(itemID: "f1", isStarred: true)
        sut.setStarred(itemID: "f1", isStarred: true)

        XCTAssertEqual(sut.items(in: .starred, parentID: nil).count, 1)
    }

    func test_setStarred_forUnknownItem_isNoOp() {
        let sut = DriveService(myDrive: [makeFile(id: "f1")])
        sut.setStarred(itemID: "missing", isStarred: true)

        XCTAssertTrue(sut.items(in: .starred, parentID: nil).isEmpty)
    }

    func test_isStarred_reflectsCurrentState() {
        let sut = DriveService(myDrive: [makeFile(id: "f1", isStarred: true)])
        XCTAssertTrue(sut.isStarred(itemID: "f1"))
        XCTAssertFalse(sut.isStarred(itemID: "nope"))
    }

    // MARK: - Request shape

    /// There is no dedicated star endpoint — it is a field on the ordinary update handler.
    func test_setStarred_patchesFileWithIsStarredField() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var method: String?
            var path: String?
            var body: Data?
            func set(_ request: URLRequest, _ body: Data?) {
                lock.lock(); defer { lock.unlock() }
                self.method = request.httpMethod
                self.path = request.url?.path
                self.body = body
            }
        }
        let captured = Box()
        let expectation = expectation(description: "PATCH issued")

        MockURLProtocol.requestHandler = { [self] request in
            captured.set(request, request.httpBody ?? MockURLProtocol.lastRequestBody)
            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!,
                    json(["id": "f1", "name": "File", "folderId": nil, "sizeBytes": 512,
                          "mimeType": "text/plain", "updatedAt": "2026-01-01T00:00:00",
                          "isStarred": true]))
        }

        let sut = DriveService(myDrive: [makeFile(id: "f1")],
                               session: MockURLProtocol.makeSession())
        sut.setStarred(itemID: "f1", isStarred: true)

        await fulfillment(of: [expectation], timeout: 2)

        XCTAssertEqual(captured.method, "PATCH")
        XCTAssertEqual(captured.path, "/api/v1/drive/files/f1")
        let body = try XCTUnwrap(captured.body)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(decoded["isStarred"] as? Bool, true)
    }

    func test_setStarred_forFolder_patchesFolderEndpoint() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var path: String?
            func set(_ value: String?) { lock.lock(); path = value; lock.unlock() }
            var value: String? { lock.lock(); defer { lock.unlock() }; return path }
        }
        let captured = Box()
        let expectation = expectation(description: "PATCH issued")

        MockURLProtocol.requestHandler = { [self] request in
            captured.set(request.url?.path)
            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!,
                    json(["id": "d1", "name": "Folder", "parentId": nil,
                          "updatedAt": "2026-01-01T00:00:00", "isStarred": true]))
        }

        let sut = DriveService(myDrive: [makeFolder(id: "d1")],
                               session: MockURLProtocol.makeSession())
        sut.setStarred(itemID: "d1", isStarred: true)

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(captured.value, "/api/v1/drive/folders/d1")
    }

    // MARK: - Rollback

    /// A failed star must not leave the UI showing a star the server never recorded.
    func test_setStarred_onServerError_rollsBackOptimisticChange() async throws {
        let expectation = expectation(description: "PATCH attempted")
        MockURLProtocol.requestHandler = { request in
            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 500,
                                    httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }

        let sut = DriveService(myDrive: [makeFile(id: "f1")],
                               session: MockURLProtocol.makeSession())
        sut.setStarred(itemID: "f1", isStarred: true)

        await fulfillment(of: [expectation], timeout: 2)
        // Let the failure path run.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(sut.allItems.first(where: { $0.id == "f1" })?.isStarred ?? true,
                       "A failed star must roll back.")
        XCTAssertTrue(sut.items(in: .starred, parentID: nil).isEmpty)
        XCTAssertNotNil(sut.error)
    }

    // MARK: - Loading

    func test_loadSection_starred_populatesStarredItems() async {
        MockURLProtocol.requestHandler = { [self] request in
            (HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!,
             json(["files": [["id": "f1", "name": "Starred File", "folderId": nil,
                              "sizeBytes": 10, "mimeType": "text/plain",
                              "updatedAt": "2026-01-01T00:00:00", "isStarred": true]],
                   "folders": [["id": "d1", "name": "Starred Folder", "parentId": nil,
                                "updatedAt": "2026-01-01T00:00:00", "isStarred": true]]]))
        }

        let sut = DriveService(session: MockURLProtocol.makeSession())
        await sut.loadSection(.starred, parentID: nil)

        XCTAssertEqual(sut.starredItems.count, 2)
        XCTAssertTrue(sut.starredItems.allSatisfy(\.isStarred))
    }

    /// The server's default limit is 5 — a "Quick Access" default that would silently truncate
    /// a Favorites list — so an explicit limit must always be sent.
    func test_loadSection_starred_sendsExplicitLimit() async {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var query: String?
            func set(_ value: String?) { lock.lock(); query = value; lock.unlock() }
            var value: String? { lock.lock(); defer { lock.unlock() }; return query }
        }
        let captured = Box()

        MockURLProtocol.requestHandler = { [self] request in
            captured.set(request.url?.query)
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!,
                    json(["files": [], "folders": []]))
        }

        let sut = DriveService(session: MockURLProtocol.makeSession())
        await sut.loadSection(.starred, parentID: nil)

        let query = captured.value ?? ""
        XCTAssertTrue(query.contains("limit="), "An explicit limit must be sent.")
        XCTAssertFalse(query.contains("limit=5"), "The 5-item Quick Access default is not a favorites list.")
    }

    /// A server that omits `isStarred` must not break listing — the field is optional.
    func test_loadSection_myDrive_toleratesMissingIsStarredField() async {
        MockURLProtocol.requestHandler = { [self] request in
            (HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!,
             json(["files": [["id": "f1", "name": "Legacy", "folderId": nil,
                              "sizeBytes": 10, "mimeType": "text/plain",
                              "updatedAt": "2026-01-01T00:00:00"]],
                   "folders": []]))
        }

        let sut = DriveService(session: MockURLProtocol.makeSession())
        await sut.loadSection(.myDrive, parentID: nil)

        XCTAssertEqual(sut.allItems.count, 1)
        XCTAssertEqual(sut.allItems.first?.isStarred, false)
        XCTAssertNil(sut.error)
    }

    // MARK: - Section gating

    func test_visibleCases_includesStarred_whenFeatureEnabled() {
        // The flag ships enabled; this pins the wiring so a future flip is a deliberate act.
        XCTAssertEqual(DriveSection.visibleCases.contains(.starred), FeatureFlags.favorites)
    }

    func test_allCases_alwaysContainsStarred_soSwitchesStayExhaustive() {
        XCTAssertTrue(DriveSection.allCases.contains(.starred))
    }
}
