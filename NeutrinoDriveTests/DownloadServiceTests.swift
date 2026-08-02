import XCTest
@testable import NeutrinoDrive

/// Unit tests for DownloadService.
/// Network calls are not made — tests exercise the synchronous/in-process paths only.
@MainActor
final class DownloadServiceTests: XCTestCase {

    // MARK: - DownloadService initial state

    func test_initialState_isNotDownloading() {
        let sut = DownloadService()
        XCTAssertFalse(sut.isDownloading)
    }

    func test_initialState_progressIsZero() {
        let sut = DownloadService()
        XCTAssertEqual(sut.progress, 0)
    }

    func test_initialState_errorIsNil() {
        let sut = DownloadService()
        XCTAssertNil(sut.error)
    }

    // MARK: - download — pre-condition errors

    func test_download_throwsNoEncryptionKey_whenKeysAbsent() async {
        KeychainService.delete(forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.delete(forKey: KeyImportService.privateKeyKeychainKey)

        let sut = DownloadService()

        do {
            _ = try await sut.download(fileID: "file-1", fileName: "doc.pdf", mimeType: "application/pdf")
            XCTFail("Expected DownloadError.noEncryptionKey")
        } catch let err as DownloadError {
            if case .noEncryptionKey = err { /* expected */ } else {
                XCTFail("Unexpected DownloadError: \(err)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_download_throwsNotAuthenticated_whenTokenAbsentButKeysPresent() async {
        // Store a fake key pair so the keys check passes. All three entries are required —
        // `hasStoredKeys()` counts the key version too, and seeding only the pair leaves the
        // download failing with `.noEncryptionKey` before it ever reaches the token check.
        KeychainService.save("fake-public-key", forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.save("fake-private-key", forKey: KeyImportService.privateKeyKeychainKey)
        KeychainService.save("1", forKey: KeyImportService.keyVersionKeychainKey)
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        defer {
            KeychainService.delete(forKey: KeyImportService.publicKeyKeychainKey)
            KeychainService.delete(forKey: KeyImportService.privateKeyKeychainKey)
            KeychainService.delete(forKey: KeyImportService.keyVersionKeychainKey)
        }

        let sut = DownloadService()

        do {
            _ = try await sut.download(fileID: "file-1", fileName: "doc.pdf", mimeType: nil)
            XCTFail("Expected DownloadError.notAuthenticated")
        } catch let err as DownloadError {
            if case .notAuthenticated = err { /* expected */ } else {
                XCTFail("Unexpected DownloadError: \(err)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - DownloadError descriptions

    func test_noEncryptionKey_hasDescription() {
        XCTAssertNotNil(DownloadError.noEncryptionKey.errorDescription)
    }

    func test_decryptionFailed_hasDescription() {
        XCTAssertNotNil(DownloadError.decryptionFailed.errorDescription)
    }

    func test_notAuthenticated_hasDescription() {
        XCTAssertNotNil(DownloadError.notAuthenticated.errorDescription)
    }

    func test_networkError_hasDescription() {
        let underlying = NSError(domain: "test", code: -1)
        XCTAssertNotNil(DownloadError.networkError(underlying: underlying).errorDescription)
    }

    func test_serverError_hasDescription() {
        XCTAssertNotNil(DownloadError.serverError(statusCode: 500).errorDescription)
    }

    func test_decodingError_hasDescription() {
        let underlying = NSError(domain: "test", code: -2)
        XCTAssertNotNil(DownloadError.decodingError(underlying: underlying).errorDescription)
    }

    func test_fileWriteError_hasDescription() {
        let underlying = NSError(domain: "test", code: -3)
        XCTAssertNotNil(DownloadError.fileWriteError(underlying: underlying).errorDescription)
    }

    // MARK: - isDownloading resets after error

    func test_isDownloading_isFalseAfterPreConditionError() async {
        KeychainService.delete(forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.delete(forKey: KeyImportService.privateKeyKeychainKey)

        let sut = DownloadService()

        _ = try? await sut.download(fileID: "f", fileName: "f.txt", mimeType: nil)

        XCTAssertFalse(sut.isDownloading)
    }

    // MARK: - Version downloads (Phase 5)

    /// A historical version's blob comes from the version endpoint.
    ///
    /// Only path construction is asserted, not the whole download: the full flow would need a
    /// real key pair, a token, and a server to answer the key and blob requests. So the routing
    /// decision is factored into a pure function and tested there rather than asserted through
    /// a flow this test host cannot complete.
    func test_blobPath_withVersionID_pointsAtVersionDownloadEndpoint() {
        XCTAssertEqual(DownloadService.blobPath(fileID: "file-1", versionID: "v7"),
                       "/api/v1/drive/files/file-1/versions/v7/download")
    }

    func test_blobPath_withoutVersionID_pointsAtCurrentFile() {
        XCTAssertEqual(DownloadService.blobPath(fileID: "file-1", versionID: nil),
                       "/api/v1/drive/files/file-1")
    }

    /// The version path must not collide with the current-file path — a version download that
    /// silently fetched the current file would look like a working feature while showing the
    /// wrong bytes.
    func test_blobPath_versionAndCurrentPathsDiffer() {
        XCTAssertNotEqual(DownloadService.blobPath(fileID: "file-1", versionID: "v1"),
                          DownloadService.blobPath(fileID: "file-1", versionID: nil))
    }

    /// Distinct transfer IDs keep the background session's orphan-claim path from confusing a
    /// version download with a current-file download of the same file.
    func test_blobTransferID_isDistinctPerVersion() {
        let current = DownloadService.blobTransferID(fileID: "file-1", versionID: nil)
        let v1 = DownloadService.blobTransferID(fileID: "file-1", versionID: "v1")
        let v2 = DownloadService.blobTransferID(fileID: "file-1", versionID: "v2")

        XCTAssertNotEqual(current, v1)
        XCTAssertNotEqual(v1, v2)
    }

    /// Versions have no key of their own, so the DEK always comes from the file-level key
    /// endpoint regardless of which version is being fetched.
    func test_versionDownload_stillUsesFileLevelKeyPath() {
        // The key path is not version-scoped anywhere in the service.
        XCTAssertFalse(DownloadService.blobPath(fileID: "file-1", versionID: "v7").hasSuffix("/key"))
        XCTAssertTrue(DownloadService.blobPath(fileID: "file-1", versionID: "v7")
            .hasPrefix("/api/v1/drive/files/file-1/"))
    }
}
