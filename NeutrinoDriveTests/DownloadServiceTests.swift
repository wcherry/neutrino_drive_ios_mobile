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
        // Store a fake key pair so the keys check passes.
        KeychainService.save("fake-public-key", forKey: KeyImportService.publicKeyKeychainKey)
        KeychainService.save("fake-private-key", forKey: KeyImportService.privateKeyKeychainKey)
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        defer {
            KeychainService.delete(forKey: KeyImportService.publicKeyKeychainKey)
            KeychainService.delete(forKey: KeyImportService.privateKeyKeychainKey)
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
}
