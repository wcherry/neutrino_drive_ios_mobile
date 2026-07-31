import XCTest
@testable import NeutrinoDrive

/// Unit tests for `DriveAPIClient` — the extension-safe metadata client the File Provider
/// extension issues every request through.
///
/// The extension itself is untestable in this host, so these tests cover the layer immediately
/// beneath it: the exact requests it emits and the exact shapes it decodes. The `folderId`
/// three-state encoding and the trash-not-delete routing are the two things here that would be
/// damaging and silent if wrong.
@MainActor
final class DriveAPIClientTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = MockURLProtocol.makeSession()
        KeychainService.save("test-token", forKey: AuthService.accessTokenKey)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        super.tearDown()
    }

    // MARK: - Helpers

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func respond(status: Int = 200, body: Data,
                         capture: ((URLRequest) -> Void)? = nil) {
        MockURLProtocol.requestHandler = { request in
            capture?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
    }

    private func fileJSON(id: String = "file-1", name: String = "Report.pdf",
                          folderId: String? = "folder-1") -> [String: Any] {
        var dict: [String: Any] = [
            "id": id, "name": name, "sizeBytes": 2048,
            "mimeType": "application/pdf", "updatedAt": "2024-01-15T10:30:00",
            "isStarred": false
        ]
        dict["folderId"] = folderId as Any? ?? NSNull()
        return dict
    }

    private func folderJSON(id: String = "folder-1", name: String = "Documents",
                            parentId: String? = nil) -> [String: Any] {
        [
            "id": id, "name": name,
            "parentId": parentId as Any? ?? NSNull(),
            "updatedAt": "2024-01-15T10:30:00",
            "isStarred": false
        ]
    }

    // MARK: - listFolder

    func test_listFolder_sendsBearerToken() async throws {
        var captured: URLRequest?
        respond(body: json(["folder": NSNull(), "folders": [], "files": [], "shortcuts": []])) {
            captured = $0
        }

        _ = try await DriveAPIClient(session: session).listFolder(folderID: "folder-1")

        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func test_listFolder_decodesFilesAndFolders() async throws {
        respond(body: json([
            "folder": NSNull(),
            "folders": [folderJSON(id: "sub-1", name: "Sub")],
            "files": [fileJSON(id: "file-1", name: "Report.pdf")],
            "shortcuts": []
        ]))

        let contents = try await DriveAPIClient(session: session).listFolder(folderID: "folder-1")

        XCTAssertEqual(contents.folders.count, 1)
        XCTAssertEqual(contents.folders.first?.name, "Sub")
        XCTAssertEqual(contents.files.count, 1)
        XCTAssertEqual(contents.files.first?.name, "Report.pdf")
        XCTAssertEqual(contents.files.first?.sizeBytes, 2048)
    }

    /// `FolderContentsResponse.folder` is the *only* source of a folder's own metadata — there is
    /// no `GET /folders/{id}/metadata`. Losing this decoding would make `item(for:)` unanswerable
    /// for every folder, which presents in the Files app as folders that will not open.
    func test_listFolder_decodesOwnFolderRecord() async throws {
        respond(body: json([
            "folder": folderJSON(id: "folder-1", name: "Documents", parentId: nil),
            "folders": [], "files": [], "shortcuts": []
        ]))

        let contents = try await DriveAPIClient(session: session).listFolder(folderID: "folder-1")

        XCTAssertEqual(contents.folder?.id, "folder-1")
        XCTAssertEqual(contents.folder?.name, "Documents")
    }

    func test_listRoot_hitsDriveRootPath() async throws {
        var captured: URLRequest?
        respond(body: json(["folder": NSNull(), "folders": [], "files": [], "shortcuts": []])) {
            captured = $0
        }

        _ = try await DriveAPIClient(session: session).listFolder(folderID: nil)

        XCTAssertEqual(captured?.url?.path, "/api/v1/drive")
    }

    func test_listFolder_withID_hitsFolderPath() async throws {
        var captured: URLRequest?
        respond(body: json(["folder": NSNull(), "folders": [], "files": [], "shortcuts": []])) {
            captured = $0
        }

        _ = try await DriveAPIClient(session: session).listFolder(folderID: "abc")

        XCTAssertEqual(captured?.url?.path, "/api/v1/drive/folders/abc")
    }

    func test_listFolder_toleratesMissingIsStarredField() async throws {
        var file = fileJSON()
        file.removeValue(forKey: "isStarred")
        respond(body: json(["folder": NSNull(), "folders": [], "files": [file], "shortcuts": []]))

        let contents = try await DriveAPIClient(session: session).listFolder(folderID: nil)

        XCTAssertEqual(contents.files.count, 1)
        XCTAssertNil(contents.files.first?.isStarred)
    }

    // MARK: - Auth failure

    /// The extension cannot refresh a token — `AuthService` is not compiled into it. A 401 must
    /// therefore surface as a terminal, recognisable state, so the Files app offers a sign-in
    /// affordance rather than implying the server is broken.
    func test_listFolder_on401_throwsNotAuthenticated() async {
        respond(status: 401, body: Data("{}".utf8))

        do {
            _ = try await DriveAPIClient(session: session).listFolder(folderID: nil)
            XCTFail("Expected DriveAPIError.notAuthenticated")
        } catch let error as DriveAPIError {
            guard case .notAuthenticated = error else {
                return XCTFail("Unexpected DriveAPIError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_listFolder_on404_throwsNotFound() async {
        respond(status: 404, body: Data("{}".utf8))

        do {
            _ = try await DriveAPIClient(session: session).listFolder(folderID: "gone")
            XCTFail("Expected DriveAPIError.notFound")
        } catch let error as DriveAPIError {
            guard case .notFound = error else {
                return XCTFail("Unexpected DriveAPIError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_request_withNoToken_throwsNotAuthenticatedBeforeNetworkCall() async {
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        var madeRequest = false
        respond(body: Data("{}".utf8)) { _ in madeRequest = true }

        do {
            _ = try await DriveAPIClient(session: session).listFolder(folderID: nil)
            XCTFail("Expected DriveAPIError.notAuthenticated")
        } catch let error as DriveAPIError {
            guard case .notAuthenticated = error else {
                return XCTFail("Unexpected DriveAPIError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertFalse(madeRequest, "must not issue an unauthenticated request")
    }

    // MARK: - fileMetadata

    func test_fileMetadata_hitsMetadataPathAndDecodes() async throws {
        var captured: URLRequest?
        respond(body: json(fileJSON(id: "file-7", name: "Photo.jpg"))) { captured = $0 }

        let record = try await DriveAPIClient(session: session).fileMetadata(fileID: "file-7")

        XCTAssertEqual(captured?.url?.path, "/api/v1/drive/files/file-7/metadata")
        XCTAssertEqual(record.name, "Photo.jpg")
    }

    // MARK: - updateFile — the three-state folderId

    /// A rename must not move the file. `UpdateFileRequest.folder_id` is `Option<Option<String>>`,
    /// so an emitted `"folderId": null` means "move to root" — encoding one during a plain rename
    /// would silently relocate every renamed file to the drive root.
    func test_updateFile_rename_omitsFolderIdKey() async throws {
        respond(body: json(fileJSON()))

        _ = try await DriveAPIClient(session: session).updateFile(fileID: "file-1", name: "New.pdf")

        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(dict["name"] as? String, "New.pdf")
        XCTAssertNil(dict.index(forKey: "folderId"), "folderId must be absent, not null")
    }

    func test_updateFile_move_sendsFolderId() async throws {
        respond(body: json(fileJSON()))

        _ = try await DriveAPIClient(session: session)
            .updateFile(fileID: "file-1", folderID: .moveTo("folder-9"))

        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(dict["folderId"] as? String, "folder-9")
    }

    func test_updateFile_moveToRoot_sendsNullFolderId() async throws {
        respond(body: json(fileJSON()))

        _ = try await DriveAPIClient(session: session)
            .updateFile(fileID: "file-1", folderID: .moveTo(nil))

        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(dict.index(forKey: "folderId"), "folderId key must be present")
        XCTAssertTrue(dict["folderId"] is NSNull, "moving to root requires an explicit null")
    }

    func test_updateFile_usesPATCH() async throws {
        var captured: URLRequest?
        respond(body: json(fileJSON())) { captured = $0 }

        _ = try await DriveAPIClient(session: session).updateFile(fileID: "file-1", name: "N.pdf")

        XCTAssertEqual(captured?.httpMethod, "PATCH")
        XCTAssertEqual(captured?.url?.path, "/api/v1/drive/files/file-1")
    }

    func test_updateFolder_rename_hitsFolderEndpoint() async throws {
        var captured: URLRequest?
        respond(body: json(folderJSON())) { captured = $0 }

        _ = try await DriveAPIClient(session: session)
            .updateFolder(folderID: "folder-1", name: "Renamed")

        XCTAssertEqual(captured?.httpMethod, "PATCH")
        XCTAssertEqual(captured?.url?.path, "/api/v1/drive/folders/folder-1")

        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(dict["name"] as? String, "Renamed")
        XCTAssertNil(dict.index(forKey: "parentId"))
    }

    // MARK: - trash

    /// The Files app's affordance says "Delete" and users read it as destructive. Routing it to
    /// the permanent endpoint would let a mis-swipe in a system UI destroy an E2EE file that no
    /// server-side backup can recover — the server cannot read it either.
    func test_trash_postsToBulkTrashEndpoint() async throws {
        var captured: URLRequest?
        respond(body: json(["affected": 1])) { captured = $0 }

        _ = try await DriveAPIClient(session: session).trash(fileIDs: ["file-1"], folderIDs: [])

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/api/v1/drive/bulk/trash")

        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(dict["fileIds"] as? [String], ["file-1"])
        XCTAssertEqual(dict["folderIds"] as? [String], [])
    }

    func test_trash_forFolder_sendsFolderIds() async throws {
        respond(body: json(["affected": 1]))

        _ = try await DriveAPIClient(session: session).trash(fileIDs: [], folderIDs: ["folder-1"])

        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(dict["folderIds"] as? [String], ["folder-1"])
        XCTAssertEqual(dict["fileIds"] as? [String], [])
    }

    // MARK: - createFolder

    func test_createFolder_postsNameAndParent() async throws {
        var captured: URLRequest?
        respond(body: json(folderJSON(id: "new-1", name: "New Folder"))) { captured = $0 }

        let created = try await DriveAPIClient(session: session)
            .createFolder(name: "New Folder", parentID: "parent-1")

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/api/v1/drive/folders")
        XCTAssertEqual(created.name, "New Folder")

        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(dict["name"] as? String, "New Folder")
        XCTAssertEqual(dict["parentId"] as? String, "parent-1")
    }

    // MARK: - recentFiles (working set)

    func test_recentFiles_sendsExplicitLimitAndDecodes() async throws {
        var captured: URLRequest?
        respond(body: json(["files": [fileJSON()]])) { captured = $0 }

        let files = try await DriveAPIClient(session: session).recentFiles(limit: 100)

        XCTAssertEqual(files.count, 1)
        let query = try XCTUnwrap(captured?.url?.query)
        XCTAssertTrue(query.contains("limit=100"), "query was \(query)")
        XCTAssertTrue(query.contains("orderBy=updatedAt"), "query was \(query)")
    }

    // MARK: - Date decoding

    func test_decoder_acceptsMicrosecondTimestamps() async throws {
        var file = fileJSON()
        file["updatedAt"] = "2024-01-15T10:30:00.123456"
        respond(body: json(["folder": NSNull(), "folders": [], "files": [file], "shortcuts": []]))

        let contents = try await DriveAPIClient(session: session).listFolder(folderID: nil)

        XCTAssertEqual(contents.files.count, 1)
    }
}
