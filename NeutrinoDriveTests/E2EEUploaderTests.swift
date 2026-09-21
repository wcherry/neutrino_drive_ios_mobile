import XCTest
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
@testable import NeutrinoDrive

// MARK: - Helpers

/// Stores a syntactically-valid (32-byte) X25519-shaped public key plus placeholder
/// private-key/version/access-token entries, so `SharedStorage.hasStoredKeys()` and the
/// `crypto_box_seal` step succeed. `crypto_box_seal` only requires the recipient key to be 32
/// raw bytes — it does not verify the key belongs to a real pair — so this exercises the full
/// encryption pipeline without a real device key.
private func seedKeysAndToken() {
    let pubKeyBytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let pubKeyB64URL = pubKeyBytes.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    KeychainService.save(pubKeyB64URL, forKey: SharedStorage.Keys.publicKey)
    KeychainService.save("unused-private-key", forKey: SharedStorage.Keys.privateKey)
    KeychainService.save("1", forKey: SharedStorage.Keys.keyVersion)
    KeychainService.save("test-access-token", forKey: SharedStorage.Keys.accessToken)
}

private func clearKeysAndToken() {
    KeychainService.delete(forKey: SharedStorage.Keys.publicKey)
    KeychainService.delete(forKey: SharedStorage.Keys.privateKey)
    KeychainService.delete(forKey: SharedStorage.Keys.keyVersion)
    KeychainService.delete(forKey: SharedStorage.Keys.accessToken)
}

private func uploadResponseJSON(id: String = "server-id", name: String = "f.txt") -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "id": id,
        "name": name,
        "size_bytes": 123,
        "mime_type": "text/plain",
        "updated_at": "2024-01-01T00:00:00",
    ] as [String: Any])
}

private func okResponse(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

// MARK: - E2EEUploaderTests

/// Covers the E2EE pipeline after it was lifted out of `UploadService` so the share extension
/// could compile the same source file. `UploadServiceTests` remains the regression net for the
/// wrapper's published UI state; this file covers the protocol itself.
final class E2EEUploaderTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        clearKeysAndToken()
        super.tearDown()
    }

    private func makeSUT(pendingKeys: PendingUploadKeyStore? = nil) -> E2EEUploader {
        E2EEUploader(transferService: BackgroundTransferService(session: MockURLProtocol.makeSession()),
                     pendingKeys: pendingKeys ?? makePendingKeyStore())
    }

    /// A scratch store per test — the shared one lives in the App Group container and would
    /// leak records between tests and, worse, into the simulator's real app state.
    private func makePendingKeyStore() -> PendingUploadKeyStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return PendingUploadKeyStore(fileURL: url)
    }

    // MARK: - Multipart body shape
    //
    // The server contract is positional and stringly-typed, so these assertions are the only
    // thing standing between a refactor and a silently malformed upload.

    private func decodedBody(encryptedData: Data = Data("cipher".utf8),
                             fileName: String = "note.txt",
                             mimeType: String = "text/plain",
                             parentFolderID: String? = nil,
                             encryptedMetadata: String = "meta",
                             thumbnailBase64: String? = nil) -> String {
        let body = E2EEUploader.buildMultipartBody(
            encryptedData: encryptedData, fileName: fileName, mimeType: mimeType,
            parentFolderID: parentFolderID, encryptedMetadata: encryptedMetadata,
            thumbnailBase64: thumbnailBase64, boundary: "BOUNDARY"
        )
        return String(decoding: body, as: UTF8.self)
    }

    func test_multipartBody_includesEncryptedMetadataPart() {
        XCTAssertTrue(decodedBody().contains(#"name="encrypted_metadata""#))
    }

    func test_multipartBody_carriesTheEncryptedMetadataValue() {
        XCTAssertTrue(decodedBody(encryptedMetadata: "SEALED-META").contains("SEALED-META"))
    }

    func test_multipartBody_omitsFolderIdPart_whenUploadingToRoot() {
        XCTAssertFalse(decodedBody(parentFolderID: nil).contains(#"name="folder_id""#))
    }

    func test_multipartBody_includesFolderIdPart_whenUploadingToAFolder() {
        let body = decodedBody(parentFolderID: "folder-123")
        XCTAssertTrue(body.contains(#"name="folder_id""#))
        XCTAssertTrue(body.contains("folder-123"))
    }

    func test_multipartBody_setsPlaintextMimeTypeOnTheFilePart() {
        // The server stores this value directly; the same MIME type is also inside the
        // encrypted metadata for E2EE clients.
        XCTAssertTrue(decodedBody(mimeType: "image/heic").contains("Content-Type: image/heic"))
    }

    func test_multipartBody_setsTheFilenameOnTheFilePart() {
        XCTAssertTrue(decodedBody(fileName: "holiday.jpg").contains(#"filename="holiday.jpg""#))
    }

    func test_multipartBody_carriesTheCiphertextVerbatim() {
        let ciphertext = Data([0x00, 0xFF, 0x10, 0x42])
        let body = E2EEUploader.buildMultipartBody(
            encryptedData: ciphertext, fileName: "a", mimeType: "application/octet-stream",
            parentFolderID: nil, encryptedMetadata: "m", thumbnailBase64: nil, boundary: "B"
        )
        XCTAssertTrue(body.range(of: ciphertext) != nil)
    }

    func test_multipartBody_isTerminatedWithTheClosingBoundary() {
        XCTAssertTrue(decodedBody().hasSuffix("--BOUNDARY--\r\n"))
    }

    // MARK: - Cover thumbnail part

    func test_multipartBody_omitsThumbnailPart_whenThereIsNoThumbnail() {
        XCTAssertFalse(decodedBody(thumbnailBase64: nil).contains(#"name="thumbnail_b64""#))
    }

    func test_multipartBody_carriesTheThumbnailValue() {
        let body = decodedBody(thumbnailBase64: "QkFTRTY0LUpQRUc=")
        XCTAssertTrue(body.contains(#"name="thumbnail_b64""#))
        XCTAssertTrue(body.contains("QkFTRTY0LUpQRUc="))
    }

    func test_multipartBody_sendsTheThumbnailBeforeTheFilePart() throws {
        // Not a style preference. The server returns the moment it has consumed the file part,
        // so a thumbnail sent after the blob is silently never read and the file gets no cover.
        let body = decodedBody(thumbnailBase64: "THUMB")
        let thumbnailAt = try XCTUnwrap(body.range(of: #"name="thumbnail_b64""#))
        let fileAt = try XCTUnwrap(body.range(of: #"name="file""#))
        XCTAssertTrue(thumbnailAt.lowerBound < fileAt.lowerBound)
    }

    func test_upload_sendsACoverThumbnail_forAnImageUpload() async throws {
        seedKeysAndToken()
        var uploadBody: Data?
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                uploadBody = MockURLProtocol.lastRequestBody
                return (okResponse(request), uploadResponseJSON())
            }
            return (okResponse(request), Data())
        }

        _ = try await makeSUT().upload(data: makeTestPNG(width: 900, height: 600),
                                       fileName: "holiday.png", mimeType: "image/png",
                                       parentFolderID: nil)

        let body = String(decoding: try XCTUnwrap(uploadBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="thumbnail_b64""#),
                      "An image upload with no thumbnail leaves the file with a blank tile")
    }

    func test_upload_sendsNoThumbnail_forANonImageUpload() async throws {
        seedKeysAndToken()
        var uploadBody: Data?
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                uploadBody = MockURLProtocol.lastRequestBody
                return (okResponse(request), uploadResponseJSON())
            }
            return (okResponse(request), Data())
        }

        _ = try await makeSUT().upload(data: Data("plain text".utf8), fileName: "a.txt",
                                       mimeType: "text/plain", parentFolderID: nil)

        let body = String(decoding: try XCTUnwrap(uploadBody), as: UTF8.self)
        XCTAssertFalse(body.contains(#"name="thumbnail_b64""#))
    }

    func test_upload_prefersACoverTheCallerSupplied_overDerivingOne() async throws {
        // Photo sync supplies one for videos because it already holds the clip on disk. A derived
        // cover winning here would make that saving pointless and re-spill the whole file.
        seedKeysAndToken()
        var uploadBody: Data?
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                uploadBody = MockURLProtocol.lastRequestBody
                return (okResponse(request), uploadResponseJSON())
            }
            return (okResponse(request), Data())
        }

        _ = try await makeSUT().upload(data: makeTestPNG(width: 900, height: 600),
                                       fileName: "holiday.png", mimeType: "image/png",
                                       parentFolderID: nil,
                                       thumbnailBase64: "CALLER-SUPPLIED-COVER")

        let body = String(decoding: try XCTUnwrap(uploadBody), as: UTF8.self)
        XCTAssertTrue(body.contains("CALLER-SUPPLIED-COVER"))
    }

    func test_upload_sendsACoverThumbnail_forAVideoUpload() async throws {
        seedKeysAndToken()
        let videoURL = try await makeTestVideo(frames: 30)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        var uploadBody: Data?
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                uploadBody = MockURLProtocol.lastRequestBody
                return (okResponse(request), uploadResponseJSON())
            }
            return (okResponse(request), Data())
        }

        _ = try await makeSUT().upload(data: try Data(contentsOf: videoURL), fileName: "clip.mov",
                                       mimeType: "video/quicktime", parentFolderID: nil)

        let body = String(decoding: try XCTUnwrap(uploadBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="thumbnail_b64""#),
                      "A video upload with no poster frame leaves the clip with a blank tile")
    }

    func test_upload_stillSucceeds_whenTheImageCannotBeDecoded() async throws {
        // A thumbnail is a nicety; nothing about failing to make one may cost the user the
        // upload itself.
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                return (okResponse(request), uploadResponseJSON(id: "still-uploaded"))
            }
            return (okResponse(request), Data())
        }

        let result = try await makeSUT().upload(data: Data("not really a jpeg".utf8),
                                                fileName: "broken.jpg", mimeType: "image/jpeg",
                                                parentFolderID: nil)

        XCTAssertEqual(result.id, "still-uploaded")
    }

    // MARK: - Preconditions

    func test_upload_throwsNoEncryptionKey_whenKeysAbsent() async {
        clearKeysAndToken()
        do {
            _ = try await makeSUT().upload(data: Data("x".utf8), fileName: "a.txt",
                                           mimeType: "text/plain", parentFolderID: nil)
            XCTFail("Expected UploadError.noEncryptionKey")
        } catch let error as UploadError {
            guard case .noEncryptionKey = error else {
                return XCTFail("Unexpected UploadError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_upload_throwsNotAuthenticated_whenTokenAbsentButKeysPresent() async {
        seedKeysAndToken()
        KeychainService.delete(forKey: SharedStorage.Keys.accessToken)

        do {
            _ = try await makeSUT().upload(data: Data("x".utf8), fileName: "a.txt",
                                           mimeType: "text/plain", parentFolderID: nil)
            XCTFail("Expected UploadError.notAuthenticated")
        } catch let error as UploadError {
            guard case .notAuthenticated = error else {
                return XCTFail("Unexpected UploadError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Round trip

    func test_upload_postsCiphertext_neverThePlaintext() async throws {
        seedKeysAndToken()
        let plaintext = Data("SECRET-SENTINEL-VALUE".utf8)
        var uploadBody: Data?

        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                uploadBody = MockURLProtocol.lastRequestBody
                return (okResponse(request), uploadResponseJSON())
            }
            return (okResponse(request), Data())
        }

        _ = try await makeSUT().upload(data: plaintext, fileName: "a.txt",
                                       mimeType: "text/plain", parentFolderID: nil)

        let body = try XCTUnwrap(uploadBody)
        XCTAssertNil(body.range(of: plaintext),
                     "The plaintext must never appear in the request body — that is the entire E2EE guarantee")
    }

    func test_upload_storesTheSealedKeyWithAPutToTheKeyEndpoint() async throws {
        seedKeysAndToken()
        var keyRequestMethods: [String: String] = [:]

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            keyRequestMethods[path] = request.httpMethod
            if path.hasSuffix("/upload") {
                return (okResponse(request), uploadResponseJSON(id: "file-77"))
            }
            return (okResponse(request), Data())
        }

        _ = try await makeSUT().upload(data: Data("x".utf8), fileName: "a.txt",
                                       mimeType: "text/plain", parentFolderID: nil)

        XCTAssertEqual(keyRequestMethods["/api/v1/drive/files/file-77/key"], "PUT")
    }

    func test_upload_returnsTheServersMetadata() async throws {
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                return (okResponse(request), uploadResponseJSON(id: "abc", name: "renamed.txt"))
            }
            return (okResponse(request), Data())
        }

        let result = try await makeSUT().upload(data: Data("x".utf8), fileName: "a.txt",
                                                mimeType: "text/plain", parentFolderID: nil)

        XCTAssertEqual(result.id, "abc")
        XCTAssertEqual(result.name, "renamed.txt")
        XCTAssertEqual(result.sizeBytes, 123)
    }

    func test_upload_throwsServerError_withTheStatusCode() async {
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { request in (okResponse(request, status: 507), Data()) }

        do {
            _ = try await makeSUT().upload(data: Data("x".utf8), fileName: "a.txt",
                                           mimeType: "text/plain", parentFolderID: nil)
            XCTFail("Expected UploadError.serverError")
        } catch let error as UploadError {
            guard case .serverError(let code) = error else {
                return XCTFail("Unexpected UploadError: \(error)")
            }
            // PhotoSyncService distinguishes permanent from retryable failures by this code.
            XCTAssertEqual(code, 507)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_upload_throwsNetworkError_whenTheTransferFails() async {
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await makeSUT().upload(data: Data("x".utf8), fileName: "a.txt",
                                           mimeType: "text/plain", parentFolderID: nil)
            XCTFail("Expected UploadError.networkError")
        } catch let error as UploadError {
            guard case .networkError = error else {
                return XCTFail("Unexpected UploadError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_upload_doesNotLeaveTheMultipartBodyFileOnDisk() async throws {
        // The body file holds ciphertext of user data; leaking one per upload into tmp would be
        // both a disk leak and an unnecessary artefact to leave lying around.
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                return (okResponse(request), uploadResponseJSON())
            }
            return (okResponse(request), Data())
        }

        let tmp = FileManager.default.temporaryDirectory
        let before = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?
            .filter { $0.hasPrefix("nd-upload-") }.count ?? 0

        _ = try await makeSUT().upload(data: Data("x".utf8), fileName: "a.txt",
                                       mimeType: "text/plain", parentFolderID: nil)

        let after = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?
            .filter { $0.hasPrefix("nd-upload-") }.count ?? 0
        XCTAssertEqual(after, before)
    }

    // MARK: - The sealed key outliving the process (issue #33)
    //
    // An upload commits in two steps on two sessions: the blob on the *background* session,
    // which survives suspension by design, and the sealed DEK on the *foreground* one, which
    // does not. Suspended between them the blob commits, the row declares itself encrypted,
    // and the DEK — held only in memory until now — goes away with the process. The file is
    // then undecryptable by every client, forever, with no error shown at the time.

    func test_upload_recordsTheSealedKeyBeforeThePlaintextIsEverPosted() async throws {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        var recordAtPostTime: PendingUploadKey?

        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/upload") == true {
                // Read the store from inside the request, which is the only moment that
                // proves the record predates the bytes rather than following them.
                recordAtPostTime = store.key(forUploadID: "upload-A")
                return (okResponse(request), uploadResponseJSON(id: "file-77"))
            }
            return (okResponse(request), Data())
        }

        _ = try await makeSUT(pendingKeys: store).upload(
            data: Data("x".utf8), fileName: "a.txt", mimeType: "text/plain",
            parentFolderID: nil, uploadID: "upload-A"
        )

        XCTAssertNotNil(recordAtPostTime,
                        "Nothing persists the DEK if the record is written after the blob")
        XCTAssertFalse(recordAtPostTime?.sealedFileKey.isEmpty ?? true)
        XCTAssertNil(recordAtPostTime?.fileID, "The blob has not been acknowledged yet")
    }

    func test_upload_clearsTheRecord_onceTheKeyIsStored() async throws {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        MockURLProtocol.requestHandler = { request in
            request.url?.path.hasSuffix("/upload") == true
                ? (okResponse(request), uploadResponseJSON(id: "file-77"))
                : (okResponse(request), Data())
        }

        _ = try await makeSUT(pendingKeys: store).upload(
            data: Data("x".utf8), fileName: "a.txt", mimeType: "text/plain",
            parentFolderID: nil, uploadID: "upload-A"
        )

        XCTAssertTrue(store.all().isEmpty, "Both halves are on the server; nothing left to protect")
    }

    /// The failure the issue is actually about. The `PUT` is the half that cannot survive
    /// suspension, so this is the state a killed process leaves behind.
    func test_upload_keepsTheRecordWithTheFileID_whenTheKeyPutFails() async {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/upload") { return (okResponse(request), uploadResponseJSON(id: "file-77")) }
            if path.hasSuffix("/key")    { return (okResponse(request, status: 503), Data()) }
            return (okResponse(request), Data())
        }

        _ = try? await makeSUT(pendingKeys: store).upload(
            data: Data("x".utf8), fileName: "a.txt", mimeType: "text/plain",
            parentFolderID: nil, uploadID: "upload-A"
        )

        let record = store.key(forUploadID: "upload-A")
        XCTAssertEqual(record?.fileID, "file-77",
                       "Without the file id there is nothing to attach the recovered key to")
        XCTAssertFalse(record?.sealedFileKey.isEmpty ?? true)
    }

    // MARK: - Resuming

    /// A retry of an upload whose blob already committed must not post the bytes again: that
    /// leaves the first file unreadable *and* creates a duplicate.
    func test_upload_withACommittedRecord_postsNoBlobAndStoresTheStoredKey() async throws {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        store.record(PendingUploadKey(uploadID: "upload-A", sealedFileKey: "EARLIER-SEALED-KEY",
                                      keyVersion: 4, fileName: "a.txt", fileID: "file-77",
                                      createdAt: Date()))

        var paths: [String] = []
        var keyBody: Data?
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/key") {
                keyBody = MockURLProtocol.lastRequestBody
                return (okResponse(request), Data())
            }
            return (okResponse(request), uploadResponseJSON(id: "file-77", name: "a.txt"))
        }

        let result = try await makeSUT(pendingKeys: store).upload(
            data: Data("x".utf8), fileName: "a.txt", mimeType: "text/plain",
            parentFolderID: nil, uploadID: "upload-A"
        )

        XCTAssertFalse(paths.contains { $0.hasSuffix("/upload") },
                       "Re-posting a committed blob duplicates the file")
        XCTAssertTrue(paths.contains("/api/v1/drive/files/file-77/key"))
        let sent = String(decoding: try XCTUnwrap(keyBody), as: UTF8.self)
        XCTAssertTrue(sent.contains("EARLIER-SEALED-KEY"),
                      "The stored key is the only one that opens the ciphertext already on the server")
        XCTAssertTrue(sent.contains("\"keyVersion\":4"),
                      "A resumed upload files its key under the version it was sealed to, not today's")
        XCTAssertEqual(result.id, "file-77")
    }

    func test_upload_clearsTheRecord_afterResumingSuccessfully() async throws {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        store.record(PendingUploadKey(uploadID: "upload-A", sealedFileKey: "EARLIER",
                                      keyVersion: 1, fileName: "a.txt", fileID: "file-77",
                                      createdAt: Date()))
        MockURLProtocol.requestHandler = { request in (okResponse(request), uploadResponseJSON(id: "file-77")) }

        _ = try await makeSUT(pendingKeys: store).upload(
            data: Data("x".utf8), fileName: "a.txt", mimeType: "text/plain",
            parentFolderID: nil, uploadID: "upload-A"
        )

        XCTAssertTrue(store.all().isEmpty)
    }

    /// The test fixture stores a public key with no matching private key, so a stored sealed
    /// DEK cannot be opened — which is also what a real rotation that retired the key version
    /// looks like. The upload has to re-key rather than reuse something it cannot read.
    func test_upload_withAnUnopenableRecordAndNoCommittedBlob_reKeysAndReposts() async throws {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        store.record(PendingUploadKey(uploadID: "upload-A", sealedFileKey: "UNOPENABLE",
                                      keyVersion: 1, fileName: "a.txt", fileID: nil,
                                      createdAt: Date()))
        var keyBody: Data?
        var postedBlob = false
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/upload") {
                postedBlob = true
                return (okResponse(request), uploadResponseJSON(id: "file-77"))
            }
            if path.hasSuffix("/key") { keyBody = MockURLProtocol.lastRequestBody }
            return (okResponse(request), Data())
        }

        _ = try await makeSUT(pendingKeys: store).upload(
            data: Data("x".utf8), fileName: "a.txt", mimeType: "text/plain",
            parentFolderID: nil, uploadID: "upload-A"
        )

        XCTAssertTrue(postedBlob, "Nothing had committed, so the ciphertext still has to go")
        let sent = String(decoding: try XCTUnwrap(keyBody), as: UTF8.self)
        XCTAssertFalse(sent.contains("UNOPENABLE"),
                       "Storing a key that cannot open the ciphertext just sent is the bug, not the fix")
    }

    // MARK: - Reconciliation

    func test_reconcilePendingKeys_storesTheKeyForACommittedBlob_andClearsTheRecord() async {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        store.record(PendingUploadKey(uploadID: "upload-A", sealedFileKey: "SEALED",
                                      keyVersion: 2, fileName: "a.txt", fileID: "file-77",
                                      createdAt: Date()))
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            return (okResponse(request), Data())
        }

        await makeSUT(pendingKeys: store).reconcilePendingKeys()

        XCTAssertEqual(paths, ["/api/v1/drive/files/file-77/key"])
        XCTAssertTrue(store.all().isEmpty)
    }

    func test_reconcilePendingKeys_keepsTheRecord_whenTheServerIsStillUnreachable() async {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        store.record(PendingUploadKey(uploadID: "upload-A", sealedFileKey: "SEALED",
                                      keyVersion: 1, fileName: "a.txt", fileID: "file-77",
                                      createdAt: Date()))
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }

        await makeSUT(pendingKeys: store).reconcilePendingKeys()

        XCTAssertEqual(store.all().count, 1, "The next launch has to be able to try again")
    }

    /// A file that has been trashed and emptied cannot be given a key, and retrying forever
    /// would mean the record never goes away.
    func test_reconcilePendingKeys_dropsTheRecord_whenTheFileIsGone() async {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        store.record(PendingUploadKey(uploadID: "upload-A", sealedFileKey: "SEALED",
                                      keyVersion: 1, fileName: "a.txt", fileID: "file-77",
                                      createdAt: Date()))
        MockURLProtocol.requestHandler = { request in (okResponse(request, status: 404), Data()) }

        await makeSUT(pendingKeys: store).reconcilePendingKeys()

        XCTAssertTrue(store.all().isEmpty)
    }

    func test_reconcilePendingKeys_ignoresARecordWhoseBlobNeverCommitted() async {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        store.record(PendingUploadKey(uploadID: "upload-A", sealedFileKey: "SEALED",
                                      keyVersion: 1, fileName: "a.txt", fileID: nil,
                                      createdAt: Date()))
        MockURLProtocol.requestHandler = { request in
            XCTFail("There is no file to attach a key to")
            return (okResponse(request), Data())
        }

        await makeSUT(pendingKeys: store).reconcilePendingKeys()

        XCTAssertEqual(store.all().count, 1, "Kept until the TTL, in case the blob did commit")
    }

    func test_reconcilePendingKeys_prunesAnAbandonedRecord() async {
        seedKeysAndToken()
        let store = makePendingKeyStore()
        store.record(PendingUploadKey(uploadID: "upload-A", sealedFileKey: "SEALED",
                                      keyVersion: 1, fileName: "a.txt", fileID: nil,
                                      createdAt: Date(timeIntervalSince1970: 0)))
        MockURLProtocol.requestHandler = { request in (okResponse(request), Data()) }

        await makeSUT(pendingKeys: store).reconcilePendingKeys(
            now: Date(timeIntervalSince1970: PendingUploadKeyStore.abandonedRecordTTL + 1)
        )

        XCTAssertTrue(store.all().isEmpty)
    }

    func test_reconcilePendingKeys_doesNothing_whenThereIsNothingPending() async {
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { request in
            XCTFail("No pending keys means no requests")
            return (okResponse(request), Data())
        }

        await makeSUT().reconcilePendingKeys()
    }

    // MARK: - Shared storage aliases
    //
    // The extraction moved these constants out of AuthService/KeyImportService. If an alias
    // ever drifts, every stored credential silently becomes unreadable.

    func test_authServiceKeys_stillResolveToTheSharedStorageValues() {
        XCTAssertEqual(AuthService.accessTokenKey, SharedStorage.Keys.accessToken)
        XCTAssertEqual(AuthService.refreshTokenKey, SharedStorage.Keys.refreshToken)
        XCTAssertEqual(AuthService.serverHostKey, SharedStorage.Keys.serverHost)
        XCTAssertEqual(AuthService.defaultHost, SharedStorage.defaultHost)
    }

    func test_keyImportServiceKeys_stillResolveToTheSharedStorageValues() {
        XCTAssertEqual(KeyImportService.publicKeyKeychainKey, SharedStorage.Keys.publicKey)
        XCTAssertEqual(KeyImportService.privateKeyKeychainKey, SharedStorage.Keys.privateKey)
        XCTAssertEqual(KeyImportService.keyVersionKeychainKey, SharedStorage.Keys.keyVersion)
    }

    func test_sharedStorageKeys_matchTheOriginalStringLiterals() {
        // The literals users' existing Keychain items are already filed under. Changing any of
        // these is a silent data-loss migration.
        XCTAssertEqual(SharedStorage.Keys.accessToken, "nd.access_token")
        XCTAssertEqual(SharedStorage.Keys.refreshToken, "nd.refresh_token")
        XCTAssertEqual(SharedStorage.Keys.serverHost, "nd.server_host")
        XCTAssertEqual(SharedStorage.Keys.publicKey, "nd.encryption.public_key")
        XCTAssertEqual(SharedStorage.Keys.privateKey, "nd.encryption.private_key")
        XCTAssertEqual(SharedStorage.Keys.keyVersion, "nd.encryption.key_version")
    }

    func test_serverHost_fallsBackToTheDefaultWhenUnset() {
        UserDefaults.standard.removeObject(forKey: SharedStorage.Keys.serverHost)
        SharedStorage.defaults.removeObject(forKey: SharedStorage.Keys.serverHost)
        XCTAssertEqual(SharedStorage.serverHost, SharedStorage.defaultHost)
    }

    func test_setServerHost_isVisibleToBothSuites() {
        SharedStorage.setServerHost("https://example.test")
        defer {
            UserDefaults.standard.removeObject(forKey: SharedStorage.Keys.serverHost)
            SharedStorage.defaults.removeObject(forKey: SharedStorage.Keys.serverHost)
        }
        XCTAssertEqual(SharedStorage.serverHost, "https://example.test")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SharedStorage.Keys.serverHost), "https://example.test")
    }
}
