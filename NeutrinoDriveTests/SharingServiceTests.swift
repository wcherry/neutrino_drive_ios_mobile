import XCTest
import Sodium
@testable import NeutrinoDrive

/// Unit tests for `SharingService`, covering the permission/key-share sequence, the E2EE
/// re-wrap, and the partial-success paths.
///
/// The re-wrap assertions here are deliberately not "a POST was made with some string". They
/// decode the `encryptedFileKey` the service actually sent and open it with the *recipient's*
/// private key — because a share that posts a well-formed but wrongly-wrapped key is exactly
/// the failure mode that produces a file the recipient cannot decrypt, and it would pass any
/// weaker assertion.
@MainActor
final class SharingServiceTests: XCTestCase {

    private let sodium = Sodium()

    // MARK: - Request Recorder

    /// Records the method+path of every request, so ordering can be asserted.
    /// `MockURLProtocol` calls its handler off the test thread, hence the lock.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []

        func record(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            calls.append("\(request.httpMethod ?? "?") \(request.url?.path ?? "")")
        }

        var recorded: [String] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }

        /// Bodies keyed by path, for asserting on what was sent.
        private var bodies: [String: Data] = [:]

        func recordBody(_ request: URLRequest) {
            guard let path = request.url?.path else { return }
            let body = request.httpBody ?? request.httpBodyStream.map(Self.drain)
            lock.lock(); defer { lock.unlock() }
            if let body { bodies[path] = body }
        }

        func body(forPath path: String) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            guard let data = bodies[path] else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        private static func drain(_ stream: InputStream) -> Data {
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: 4096)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    // MARK: - Fixtures

    private struct KeyPairFixture {
        let publicKeyB64: String
        let privateKeyB64: String
        let raw: Box.KeyPair
    }

    private func makeKeyPair() -> KeyPairFixture {
        let kp = sodium.box.keyPair()!
        return KeyPairFixture(publicKeyB64: SealedKeyCrypto.encodeBase64URL(kp.publicKey)!,
                              privateKeyB64: SealedKeyCrypto.encodeBase64URL(kp.secretKey)!,
                              raw: kp)
    }

    /// Installs a sender keypair + access token in the Keychain, as a signed-in user would have.
    private func installSenderKeys(_ keyPair: KeyPairFixture) {
        KeychainService.save(keyPair.publicKeyB64, forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.save(keyPair.privateKeyB64, forKey: KeyImportService.privateKeyKeychainKey)
        KeychainService.save("test-access-token", forKey: AuthService.accessTokenKey)
    }

    private func clearKeys() {
        KeychainService.delete(forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.delete(forKey: KeyImportService.privateKeyKeychainKey)
        KeychainService.delete(forKey: AuthService.accessTokenKey)
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func ok(_ request: URLRequest, _ object: Any) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         json(object))
    }

    private func status(_ request: URLRequest, _ code: Int) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!,
         Data("{}".utf8))
    }

    private let lookupUser: [String: Any] = ["id": "user-2", "email": "b@example.com", "name": "Bea"]

    private func permissionJSON(role: String = "viewer") -> [String: Any] {
        ["id": "perm-1", "resourceType": "file", "resourceId": "file-1",
         "userId": "user-2", "userEmail": "b@example.com", "userName": "Bea",
         "role": role, "grantedBy": "user-1", "createdAt": "2026-01-01T00:00:00"]
    }

    override func tearDown() {
        MockURLProtocol.reset()
        clearKeys()
        super.tearDown()
    }

    // MARK: - addPerson ordering

    /// The backend rejects a key share unless the recipient already has a permission
    /// (`400 RECIPIENT_NO_ACCESS`), so lookup → grant → key-share is a hard requirement, not a
    /// stylistic choice.
    func test_addPerson_issuesLookupThenGrantThenKeyShare_inThatOrder() async throws {
        let sender = makeKeyPair()
        let recipient = makeKeyPair()
        installSenderKeys(sender)

        let dek = sodium.secretStream.xchacha20poly1305.key()
        let sealedForSender = SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: sender.publicKeyB64)!
        let recorder = Recorder()

        MockURLProtocol.requestHandler = { [self] request in
            recorder.record(request)
            let path = request.url?.path ?? ""
            switch path {
            case "/api/v1/auth/users/lookup":
                return ok(request, lookupUser)
            case "/api/v1/drive/files/file-1/permissions":
                return ok(request, permissionJSON())
            case "/api/v1/drive/files/file-1/key":
                return ok(request, ["fileId": "file-1", "userId": "user-1",
                                    "encryptedFileKey": sealedForSender])
            case "/api/v1/auth/users/user-2/public-key":
                return ok(request, ["userId": "user-2", "publicKey": recipient.publicKeyB64])
            case "/api/v1/drive/files/file-1/key/share":
                return ok(request, ["fileId": "file-1", "userId": "user-2",
                                    "encryptedFileKey": "stored"])
            default:
                return status(request, 404)
            }
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        try await sut.addPerson(email: "b@example.com", role: .viewer,
                                resourceType: .file, resourceID: "file-1")

        let calls = recorder.recorded
        let grantIndex = try XCTUnwrap(calls.firstIndex(of: "POST /api/v1/drive/files/file-1/permissions"))
        let shareIndex = try XCTUnwrap(calls.firstIndex(of: "POST /api/v1/drive/files/file-1/key/share"))
        let lookupIndex = try XCTUnwrap(calls.firstIndex(of: "GET /api/v1/auth/users/lookup"))

        XCTAssertLessThan(lookupIndex, grantIndex, "Lookup must resolve the user before granting.")
        XCTAssertLessThan(grantIndex, shareIndex,
                          "The permission must be granted before the key share, or the server rejects it.")
    }

    // MARK: - The re-wrap itself

    /// The key posted to `key/share` must open with the RECIPIENT's private key and must not
    /// open with the sender's. This is the assertion that would catch a wrong wrap.
    func test_addPerson_postsDEKResealedToRecipientPublicKey() async throws {
        let sender = makeKeyPair()
        let recipient = makeKeyPair()
        installSenderKeys(sender)

        let dek = sodium.secretStream.xchacha20poly1305.key()
        let sealedForSender = SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: sender.publicKeyB64)!
        let recorder = Recorder()

        MockURLProtocol.requestHandler = { [self] request in
            recorder.record(request)
            recorder.recordBody(request)
            switch request.url?.path ?? "" {
            case "/api/v1/auth/users/lookup":
                return ok(request, lookupUser)
            case "/api/v1/drive/files/file-1/permissions":
                return ok(request, permissionJSON())
            case "/api/v1/drive/files/file-1/key":
                return ok(request, ["fileId": "file-1", "userId": "user-1",
                                    "encryptedFileKey": sealedForSender])
            case "/api/v1/auth/users/user-2/public-key":
                return ok(request, ["userId": "user-2", "publicKey": recipient.publicKeyB64])
            case "/api/v1/drive/files/file-1/key/share":
                return ok(request, ["fileId": "file-1", "userId": "user-2",
                                    "encryptedFileKey": "stored"])
            default:
                return status(request, 404)
            }
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        try await sut.addPerson(email: "b@example.com", role: .viewer,
                                resourceType: .file, resourceID: "file-1")

        let body = try XCTUnwrap(recorder.body(forPath: "/api/v1/drive/files/file-1/key/share"))
        XCTAssertEqual(body["recipientId"] as? String, "user-2")
        let posted = try XCTUnwrap(body["encryptedFileKey"] as? String)

        // The recipient can open it, and recovers the ORIGINAL DEK.
        let recovered = SealedKeyCrypto.openDEK(sealedBase64URL: posted,
                                                publicKeyBase64URL: recipient.publicKeyB64,
                                                privateKeyBase64URL: recipient.privateKeyB64)
        XCTAssertEqual(recovered, dek, "The recipient must recover the file's real DEK.")

        // And it is genuinely re-wrapped, not the sender's copy forwarded.
        XCTAssertNil(SealedKeyCrypto.openDEK(sealedBase64URL: posted,
                                             publicKeyBase64URL: sender.publicKeyB64,
                                             privateKeyBase64URL: sender.privateKeyB64),
                     "The posted key must be sealed to the recipient, not the sender.")
        XCTAssertNotEqual(posted, sealedForSender)
    }

    // MARK: - Folders

    /// Folders have no DEK, so no key endpoints should be touched at all.
    func test_addPerson_forFolder_grantsPermissionAndIssuesNoKeyShare() async throws {
        installSenderKeys(makeKeyPair())
        let recorder = Recorder()

        MockURLProtocol.requestHandler = { [self] request in
            recorder.record(request)
            switch request.url?.path ?? "" {
            case "/api/v1/auth/users/lookup":
                return ok(request, lookupUser)
            case "/api/v1/drive/folders/folder-1/permissions":
                return ok(request, permissionJSON())
            default:
                return status(request, 404)
            }
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        try await sut.addPerson(email: "b@example.com", role: .editor,
                                resourceType: .folder, resourceID: "folder-1")

        XCTAssertTrue(recorder.recorded.contains("POST /api/v1/drive/folders/folder-1/permissions"))
        XCTAssertFalse(recorder.recorded.contains { $0.contains("/key") },
                       "Folder sharing must not touch any key endpoint.")
        XCTAssertEqual(sut.permissions.count, 1)
    }

    // MARK: - Partial success

    /// A recipient who has never registered a public key: the permission stands, but the file
    /// cannot be decrypted by them. That must surface as `keyShareFailed`, not as success.
    func test_addPerson_whenRecipientHasNoPublicKey_throwsKeyShareFailedButKeepsPermission() async throws {
        let sender = makeKeyPair()
        installSenderKeys(sender)
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let sealedForSender = SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: sender.publicKeyB64)!

        MockURLProtocol.requestHandler = { [self] request in
            switch request.url?.path ?? "" {
            case "/api/v1/auth/users/lookup":
                return ok(request, lookupUser)
            case "/api/v1/drive/files/file-1/permissions":
                return ok(request, permissionJSON())
            case "/api/v1/drive/files/file-1/key":
                return ok(request, ["fileId": "file-1", "userId": "user-1",
                                    "encryptedFileKey": sealedForSender])
            case "/api/v1/auth/users/user-2/public-key":
                return status(request, 404)   // recipient never registered a key
            default:
                return status(request, 404)
            }
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())

        do {
            try await sut.addPerson(email: "b@example.com", role: .viewer,
                                    resourceType: .file, resourceID: "file-1")
            XCTFail("Expected keyShareFailed")
        } catch let error as SharingError {
            guard case .keyShareFailed(_, let reason) = error else {
                return XCTFail("Expected keyShareFailed, got \(error)")
            }
            guard case .recipientHasNoPublicKey = reason else {
                return XCTFail("Expected recipientHasNoPublicKey, got \(reason)")
            }
        }

        XCTAssertEqual(sut.permissions.count, 1,
                       "The granted permission must survive a failed key share.")
    }

    /// A file that was never encrypted has no key ref; sharing it is not an error condition
    /// worth blocking on, but it must be reported distinctly.
    func test_addPerson_whenFileHasNoKeyRef_reportsFileHasNoKey() async throws {
        installSenderKeys(makeKeyPair())

        MockURLProtocol.requestHandler = { [self] request in
            switch request.url?.path ?? "" {
            case "/api/v1/auth/users/lookup":
                return ok(request, lookupUser)
            case "/api/v1/drive/files/file-1/permissions":
                return ok(request, permissionJSON())
            case "/api/v1/drive/files/file-1/key":
                return status(request, 404)
            default:
                return status(request, 404)
            }
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        do {
            try await sut.addPerson(email: "b@example.com", role: .viewer,
                                    resourceType: .file, resourceID: "file-1")
            XCTFail("Expected keyShareFailed")
        } catch let error as SharingError {
            guard case .keyShareFailed(_, let reason) = error,
                  case .fileHasNoKey = reason else {
                return XCTFail("Expected fileHasNoKey, got \(error)")
            }
        }
    }

    // MARK: - Lookup failure

    /// An unknown email must fail before any permission is granted.
    func test_addPerson_whenUserNotFound_throwsUserNotFoundAndGrantsNothing() async throws {
        installSenderKeys(makeKeyPair())
        let recorder = Recorder()

        MockURLProtocol.requestHandler = { [self] request in
            recorder.record(request)
            return status(request, 404)
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        do {
            try await sut.addPerson(email: "nobody@example.com", role: .viewer,
                                    resourceType: .file, resourceID: "file-1")
            XCTFail("Expected userNotFound")
        } catch let error as SharingError {
            guard case .userNotFound = error else {
                return XCTFail("Expected userNotFound, got \(error)")
            }
        }

        XCTAssertFalse(recorder.recorded.contains { $0.contains("permissions") },
                       "No permission may be granted when the recipient does not exist.")
        XCTAssertTrue(sut.permissions.isEmpty)
    }

    // MARK: - Listing and revoking

    func test_loadPermissions_decodesPermissionList() async {
        installSenderKeys(makeKeyPair())
        MockURLProtocol.requestHandler = { [self] request in
            ok(request, ["permissions": [permissionJSON(role: "editor")]])
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        await sut.loadPermissions(resourceType: .file, resourceID: "file-1")

        XCTAssertEqual(sut.permissions.count, 1)
        XCTAssertEqual(sut.permissions.first?.userEmail, "b@example.com")
        XCTAssertEqual(sut.permissions.first?.role, .editor)
        XCTAssertNil(sut.error)
    }

    func test_revoke_removesPermissionFromPublishedList() async throws {
        installSenderKeys(makeKeyPair())
        MockURLProtocol.requestHandler = { [self] request in
            if request.httpMethod == "DELETE" { return status(request, 204) }
            return ok(request, ["permissions": [permissionJSON()]])
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        await sut.loadPermissions(resourceType: .file, resourceID: "file-1")
        XCTAssertEqual(sut.permissions.count, 1)

        try await sut.revoke(userID: "user-2", resourceType: .file, resourceID: "file-1")
        XCTAssertTrue(sut.permissions.isEmpty)
    }

    func test_updateRole_replacesRoleInPublishedList() async throws {
        installSenderKeys(makeKeyPair())
        MockURLProtocol.requestHandler = { [self] request in
            if request.httpMethod == "PATCH" { return ok(request, permissionJSON(role: "editor")) }
            return ok(request, ["permissions": [permissionJSON(role: "viewer")]])
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        await sut.loadPermissions(resourceType: .file, resourceID: "file-1")
        XCTAssertEqual(sut.permissions.first?.role, .viewer)

        try await sut.updateRole(userID: "user-2", to: .editor,
                                 resourceType: .file, resourceID: "file-1")
        XCTAssertEqual(sut.permissions.first?.role, .editor)
    }

    // MARK: - Share links

    /// The backend exposes share-link upsert as PUT, not POST.
    func test_createShareLink_usesPUTAndDecodesToken() async throws {
        installSenderKeys(makeKeyPair())
        let recorder = Recorder()

        MockURLProtocol.requestHandler = { [self] request in
            recorder.record(request)
            recorder.recordBody(request)
            return ok(request, ["id": "link-1", "resourceType": "file", "resourceId": "file-1",
                                "token": "tok-abc", "visibility": "anyone_with_link",
                                "role": "viewer", "isActive": true, "createdBy": "user-1",
                                "createdAt": "2026-01-01T00:00:00",
                                "updatedAt": "2026-01-01T00:00:00"])
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        let link = try await sut.createShareLink(resourceType: .file, resourceID: "file-1")

        XCTAssertEqual(link.token, "tok-abc")
        XCTAssertTrue(link.isActive)
        XCTAssertTrue(recorder.recorded.contains("PUT /api/v1/drive/files/file-1/share-link"),
                      "Share-link upsert is PUT in the backend, not POST.")

        // The request enum serialises camelCase even though the response echoes snake_case.
        let body = try XCTUnwrap(recorder.body(forPath: "/api/v1/drive/files/file-1/share-link"))
        XCTAssertEqual(body["visibility"] as? String, "anyoneWithLink")
    }

    /// Opening the share sheet must not fetch the link, because `GET /share-link` creates one
    /// as a side effect. This asserts the service exposes no such implicit fetch on load.
    func test_loadPermissions_doesNotTouchShareLinkEndpoint() async {
        installSenderKeys(makeKeyPair())
        let recorder = Recorder()
        MockURLProtocol.requestHandler = { [self] request in
            recorder.record(request)
            return ok(request, ["permissions": []])
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        await sut.loadPermissions(resourceType: .file, resourceID: "file-1")

        XCTAssertFalse(recorder.recorded.contains { $0.contains("share-link") },
                       "GET /share-link creates a link as a side effect; it must not be called implicitly.")
    }

    // MARK: - Reset

    func test_reset_clearsPerResourceState() async {
        installSenderKeys(makeKeyPair())
        MockURLProtocol.requestHandler = { [self] request in
            ok(request, ["permissions": [permissionJSON()]])
        }

        let sut = SharingService(session: MockURLProtocol.makeSession())
        await sut.loadPermissions(resourceType: .file, resourceID: "file-1")
        XCTAssertFalse(sut.permissions.isEmpty)

        sut.reset()
        XCTAssertTrue(sut.permissions.isEmpty)
        XCTAssertNil(sut.shareLink)
    }
}
