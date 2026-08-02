import XCTest
@testable import NeutrinoDrive

/// Unit tests for `VersionHistoryService` — listing, ordering, date decoding, and restore.
///
/// Note what is *not* here: decrypting a historical version. That deliberately has no code of
/// its own — it runs through `DownloadService.download(…versionID:)` — so its coverage lives in
/// `DownloadServiceTests`, which asserts the version blob URL while the key still comes from
/// the file's own key endpoint.
@MainActor
final class VersionHistoryServiceTests: XCTestCase {

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func ok(_ request: URLRequest, _ object: Any) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         json(object))
    }

    private func version(id: String, number: Int, label: String? = nil,
                         isNamed: Bool = false,
                         createdAt: String = "2026-01-01T00:00:00Z") -> [String: Any] {
        var dict: [String: Any] = ["id": id, "fileId": "file-1", "versionNumber": number,
                                   "sizeBytes": 2048, "createdAt": createdAt, "isNamed": isNamed]
        if let label { dict["label"] = label }
        return dict
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

    // MARK: - Loading

    func test_loadVersions_decodesVersionList() async {
        MockURLProtocol.requestHandler = { [self] request in
            ok(request, ["versions": [version(id: "v1", number: 1)]])
        }

        let sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        await sut.loadVersions(fileID: "file-1")

        XCTAssertEqual(sut.versions.count, 1)
        XCTAssertEqual(sut.versions.first?.id, "v1")
        XCTAssertEqual(sut.versions.first?.sizeBytes, 2048)
        XCTAssertNil(sut.error)
    }

    /// The endpoint accepts `orderBy`/`direction`, so server order is not guaranteed to be the
    /// order this UI wants. Sorting is asserted rather than assumed.
    func test_loadVersions_sortsNewestFirst_regardlessOfServerOrder() async {
        MockURLProtocol.requestHandler = { [self] request in
            ok(request, ["versions": [version(id: "v2", number: 2),
                                      version(id: "v5", number: 5),
                                      version(id: "v1", number: 1)]])
        }

        let sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        await sut.loadVersions(fileID: "file-1")

        XCTAssertEqual(sut.versions.map(\.versionNumber), [5, 2, 1])
    }

    func test_loadVersions_requestsTheVersionsEndpoint() async {
        var requestedPath: String?
        MockURLProtocol.requestHandler = { [self] request in
            requestedPath = request.url?.path
            return ok(request, ["versions": []])
        }

        let sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        await sut.loadVersions(fileID: "file-1")

        XCTAssertEqual(requestedPath, "/api/v1/drive/files/file-1/versions")
    }

    func test_loadVersions_onServerError_setsErrorAndLeavesVersionsEmpty() async {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500,
                             httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }

        let sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        await sut.loadVersions(fileID: "file-1")

        XCTAssertTrue(sut.versions.isEmpty)
        XCTAssertNotNil(sut.error)
    }

    // MARK: - Date decoding

    /// The version DTO emits an RFC 3339 `DateTime<Utc>` with a zone — unlike the file/folder
    /// DTOs elsewhere in this API, which emit a bare `NaiveDateTime`. Both must decode.
    func test_loadVersions_decodesZonedISO8601Date() async throws {
        MockURLProtocol.requestHandler = { [self] request in
            ok(request, ["versions": [version(id: "v1", number: 1,
                                              createdAt: "2026-03-04T05:06:07Z")]])
        }

        let sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        await sut.loadVersions(fileID: "file-1")

        let created = try XCTUnwrap(sut.versions.first?.createdAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(calendar.component(.year, from: created), 2026)
        XCTAssertEqual(calendar.component(.month, from: created), 3)
        XCTAssertEqual(calendar.component(.day, from: created), 4)
    }

    func test_loadVersions_decodesNaiveDateTimeFallback() async {
        MockURLProtocol.requestHandler = { [self] request in
            ok(request, ["versions": [version(id: "v1", number: 1,
                                              createdAt: "2026-03-04T05:06:07.123456")]])
        }

        let sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        await sut.loadVersions(fileID: "file-1")

        XCTAssertEqual(sut.versions.count, 1, "A microsecond NaiveDateTime must still decode.")
        XCTAssertNil(sut.error)
    }

    // MARK: - Display name

    func test_displayName_usesLabelWhenPresent() async throws {
        MockURLProtocol.requestHandler = { [self] request in
            ok(request, ["versions": [version(id: "v1", number: 3, label: "Before edit", isNamed: true)]])
        }

        let sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        await sut.loadVersions(fileID: "file-1")

        XCTAssertEqual(sut.versions.first?.displayName, "Before edit")
        XCTAssertEqual(sut.versions.first?.isNamed, true)
    }

    func test_displayName_fallsBackToVersionNumber_whenUnlabelled() async {
        MockURLProtocol.requestHandler = { [self] request in
            ok(request, ["versions": [version(id: "v1", number: 7)]])
        }

        let sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        await sut.loadVersions(fileID: "file-1")

        XCTAssertEqual(sut.versions.first?.displayName, "Version 7")
    }

    // MARK: - Restore

    func test_restore_postsToRestorePathAndReloadsVersions() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var calls: [String] = []
            func add(_ value: String) { lock.lock(); calls.append(value); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return calls }
        }
        let recorder = Box()

        MockURLProtocol.requestHandler = { [self] request in
            let path = request.url?.path ?? ""
            recorder.add("\(request.httpMethod ?? "?") \(path)")
            if path.hasSuffix("/restore") {
                return ok(request, ["id": "file-1"])
            }
            return ok(request, ["versions": [version(id: "v1", number: 1)]])
        }

        let sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        try await sut.restore(fileID: "file-1", versionID: "v9")

        XCTAssertTrue(recorder.all.contains("POST /api/v1/drive/files/file-1/versions/v9/restore"))
        // Restore also snapshots the current content as a new version, so the list must refresh.
        XCTAssertTrue(recorder.all.contains("GET /api/v1/drive/files/file-1/versions"))
        XCTAssertEqual(sut.versions.count, 1)
    }

    func test_restore_onServerError_throws() async {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403,
                             httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }

        let sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        do {
            try await sut.restore(fileID: "file-1", versionID: "v9")
            XCTFail("Expected an error")
        } catch {
            // Expected.
        }
    }
}
