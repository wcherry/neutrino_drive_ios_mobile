import XCTest
@testable import NeutrinoDrive

// MARK: - Test helpers (module-level, no actor isolation)

/// Minimal `APIUploadResponse`-shaped JSON so `MockURLProtocol` can stand in for
/// `POST /api/v1/drive/files/upload`.
private func uploadResponseJSON(name: String, id: String = "server-id") -> Data {
    let dict: [String: Any] = [
        "id": id,
        "name": name,
        "size_bytes": 123,
        "mime_type": "text/plain",
        "updated_at": "2024-01-01T00:00:00",
    ]
    return try! JSONSerialization.data(withJSONObject: dict)
}

private func okResponse(for request: URLRequest) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
}

/// Stores a syntactically-valid (32-byte) X25519-shaped public key plus placeholder
/// private-key/version/access-token entries so `KeyImportService.hasStoredKeys()` and
/// `UploadService`'s `crypto_box_seal` step succeed. `crypto_box_seal` only requires the
/// recipient key to be 32 raw bytes — it does not verify the key belongs to a real pair —
/// so this is sufficient to exercise the encryption pipeline without a real device key.
private func seedValidKeysAndToken() {
    let pubKeyBytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let pubKeyB64URL = pubKeyBytes.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    KeychainService.save(pubKeyB64URL, forKey: KeyImportService.publicKeyKeychainKey)
    KeychainService.save("unused-private-key", forKey: KeyImportService.privateKeyKeychainKey)
    KeychainService.save("1", forKey: KeyImportService.keyVersionKeychainKey)
    KeychainService.save("test-access-token", forKey: AuthService.accessTokenKey)
}

private func clearKeysAndToken() {
    KeychainService.delete(forKey: KeyImportService.publicKeyKeychainKey)
    KeychainService.delete(forKey: KeyImportService.privateKeyKeychainKey)
    KeychainService.delete(forKey: KeyImportService.keyVersionKeychainKey)
    KeychainService.delete(forKey: AuthService.accessTokenKey)
}

/// Unit tests for UploadService and DriveService.fileWasUploaded.
/// Network calls are not made — tests exercise the synchronous/in-process paths only.
@MainActor
final class UploadServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeUploadResult(
        id: String = "file-1",
        name: String = "test.txt",
        folderId: String? = nil,
        sizeBytes: Int64 = 512,
        mimeType: String = "text/plain"
    ) -> UploadResult {
        UploadResult(id: id, name: name, folderId: folderId,
                     sizeBytes: sizeBytes, mimeType: mimeType, updatedAt: Date())
    }

    // MARK: - UploadService initial state

    func test_initialState_isNotUploading() {
        let sut = UploadService()
        XCTAssertFalse(sut.isUploading)
    }

    func test_initialState_progressIsZero() {
        let sut = UploadService()
        XCTAssertEqual(sut.progress, 0)
    }

    func test_initialState_errorIsNil() {
        let sut = UploadService()
        XCTAssertNil(sut.error)
    }

    // MARK: - upload — pre-condition errors

    func test_upload_throwsNoEncryptionKey_whenKeysAbsent() async {
        // Make sure no keys are stored in the test keychain slot.
        KeychainService.delete(forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.delete(forKey: KeyImportService.privateKeyKeychainKey)

        let sut = UploadService()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? "hello".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await sut.upload(fileURL: tempURL, parentFolderID: nil)
            XCTFail("Expected UploadError.noEncryptionKey")
        } catch let err as UploadError {
            if case .noEncryptionKey = err { /* expected */ } else {
                XCTFail("Unexpected error: \(err)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - DriveService.fileWasUploaded

    func test_fileWasUploaded_addsItemToAllItems() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u1", name: "photo.jpg")

        sut.fileWasUploaded(result)

        XCTAssertTrue(sut.allItems.contains(where: { $0.id == "u1" }))
    }

    func test_fileWasUploaded_itemHasCorrectName() {
        let sut = DriveService()
        let result = makeUploadResult(name: "document.pdf")

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.name == "document.pdf" })?.name, "document.pdf")
    }

    func test_fileWasUploaded_itemTypeIsFile() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u2")

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "u2" })?.type, .file)
    }

    func test_fileWasUploaded_itemHasCorrectParentID() {
        let sut = DriveService()
        sut.debugMarkLoaded(parentID: "parent-folder")
        let result = makeUploadResult(id: "u3", folderId: "parent-folder")

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "u3" })?.parentID, "parent-folder")
    }

    func test_fileWasUploaded_itemNotTrashed() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u4")

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "u4" })?.isTrashed, false)
    }

    func test_fileWasUploaded_itemHasCorrectSize() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u5", sizeBytes: 4096)

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "u5" })?.size, 4096)
    }

    func test_fileWasUploaded_itemHasCorrectMimeType() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u6", mimeType: "image/jpeg")

        sut.fileWasUploaded(result)

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "u6" })?.mimeType, "image/jpeg")
    }

    func test_fileWasUploaded_appearsInMyDriveSection_whenNoParent() {
        let sut = DriveService()
        let result = makeUploadResult(id: "u7", folderId: nil)

        sut.fileWasUploaded(result)

        let visible = sut.items(in: .myDrive, parentID: nil)
        XCTAssertTrue(visible.contains(where: { $0.id == "u7" }))
    }

    func test_fileWasUploaded_appearsInSubfolder_whenParentSet() {
        let sut = DriveService()
        sut.debugMarkLoaded(parentID: "folder-abc")
        let result = makeUploadResult(id: "u8", folderId: "folder-abc")

        sut.fileWasUploaded(result)

        let visible = sut.items(in: .myDrive, parentID: "folder-abc")
        XCTAssertTrue(visible.contains(where: { $0.id == "u8" }))
    }

    func test_fileWasUploaded_multipleUploads_allAppear() {
        let sut = DriveService()
        let r1 = makeUploadResult(id: "a", name: "a.txt")
        let r2 = makeUploadResult(id: "b", name: "b.txt")

        sut.fileWasUploaded(r1)
        sut.fileWasUploaded(r2)

        XCTAssertTrue(sut.allItems.contains(where: { $0.id == "a" }))
        XCTAssertTrue(sut.allItems.contains(where: { $0.id == "b" }))
    }

    // MARK: - Data-based primitive vs. fileURL wrapper (UploadService refactor)

    /// The `Data`-based primitive and the `fileURL` wrapper must run the same encryption
    /// pipeline for the same content. Ciphertext bytes themselves can never be literally
    /// identical between two calls — the DEK and secretstream nonce are freshly randomised
    /// each time by design — but the multipart request body's *length* is fully determined
    /// by (plaintext length, fileName, mimeType, folder), so it is the strongest true
    /// "byte-identical output" guarantee available without weakening the encryption.
    func test_uploadDataPrimitive_andUploadFileURL_produceSameRequestBodyLength_forSameContent() async throws {
        seedValidKeysAndToken()
        defer { clearKeysAndToken() }

        let plaintext = Data("Identical content for both upload paths.".utf8)
        let fileName = "shared-name.txt"
        let mimeType = "text/plain"

        var capturedUploadBodyLengths: [Int] = []
        MockURLProtocol.requestHandler = { request in
            let bodyLength = MockURLProtocol.lastRequestBody?.count ?? 0
            if request.url?.path.hasSuffix("/upload") == true {
                capturedUploadBodyLengths.append(bodyLength)
                return (okResponse(for: request), uploadResponseJSON(name: fileName))
            }
            return (okResponse(for: request), Data())
        }
        defer { MockURLProtocol.reset() }

        let sut = UploadService(session: MockURLProtocol.makeSession())

        // Path 1: the Data-based primitive directly.
        _ = try await sut.upload(data: plaintext, fileName: fileName, mimeType: mimeType, parentFolderID: nil)

        // Path 2: the fileURL wrapper — same bytes, written to a temp file with the same name,
        // so MIME sniffing resolves to the same "text/plain".
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let tempURL = tempDir.appendingPathComponent(fileName)
        try plaintext.write(to: tempURL)

        _ = try await sut.upload(fileURL: tempURL, parentFolderID: nil)

        XCTAssertEqual(capturedUploadBodyLengths.count, 2)
        XCTAssertEqual(capturedUploadBodyLengths[0], capturedUploadBodyLengths[1])
    }

    func test_upload_reportsProgressFalse_leavesIsUploadingAndProgressUntouched() async throws {
        seedValidKeysAndToken()
        defer { clearKeysAndToken() }

        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                return (okResponse(for: request), uploadResponseJSON(name: "silent.txt"))
            }
            return (okResponse(for: request), Data())
        }
        defer { MockURLProtocol.reset() }

        let sut = UploadService(session: MockURLProtocol.makeSession())
        XCTAssertFalse(sut.isUploading)
        XCTAssertEqual(sut.progress, 0)

        _ = try await sut.upload(data: Data("quiet upload".utf8), fileName: "silent.txt",
                                 mimeType: "text/plain", parentFolderID: nil, reportsProgress: false)

        XCTAssertFalse(sut.isUploading, "reportsProgress: false must never toggle isUploading — that would hijack UploadSheet's UI")
        XCTAssertEqual(sut.progress, 0, "reportsProgress: false must leave progress untouched")
    }

    func test_upload_reportsProgressTrue_setsProgressToOneOnSuccess() async throws {
        seedValidKeysAndToken()
        defer { clearKeysAndToken() }

        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                return (okResponse(for: request), uploadResponseJSON(name: "loud.txt"))
            }
            return (okResponse(for: request), Data())
        }
        defer { MockURLProtocol.reset() }

        let sut = UploadService(session: MockURLProtocol.makeSession())

        _ = try await sut.upload(data: Data("loud upload".utf8), fileName: "loud.txt",
                                 mimeType: "text/plain", parentFolderID: nil, reportsProgress: true)

        XCTAssertEqual(sut.progress, 1)
    }
}
