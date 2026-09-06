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

    private func makeSUT() -> E2EEUploader {
        E2EEUploader(transferService: BackgroundTransferService(session: MockURLProtocol.makeSession()))
    }

    // MARK: - Multipart body shape
    //
    // The server contract is positional and stringly-typed, so these assertions are the only
    // thing standing between a refactor and a silently malformed upload.

    private func decodedBody(encryptedData: Data = Data("cipher".utf8),
                             fileName: String = "note.txt",
                             mimeType: String = "text/plain",
                             parentFolderID: String? = nil,
                             encryptedMetadata: String = "meta") -> String {
        let body = E2EEUploader.buildMultipartBody(
            encryptedData: encryptedData, fileName: fileName, mimeType: mimeType,
            parentFolderID: parentFolderID, encryptedMetadata: encryptedMetadata,
            boundary: "BOUNDARY"
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
            parentFolderID: nil, encryptedMetadata: "m", boundary: "B"
        )
        XCTAssertTrue(body.range(of: ciphertext) != nil)
    }

    func test_multipartBody_isTerminatedWithTheClosingBoundary() {
        XCTAssertTrue(decodedBody().hasSuffix("--BOUNDARY--\r\n"))
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
