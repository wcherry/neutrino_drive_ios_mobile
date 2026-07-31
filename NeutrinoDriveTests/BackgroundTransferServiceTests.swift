import XCTest
@testable import NeutrinoDrive

/// Tests for the async/delegate bridge in `BackgroundTransferService`.
///
/// **Scope limit, stated up front:** these run against a *foreground* session backed by
/// `MockURLProtocol`. `URLProtocol` subclasses are never consulted by a `.background`
/// `URLSessionConfiguration`, so the real background path — surviving app suspension, being
/// relaunched via `handleEventsForBackgroundURLSession` — cannot be exercised in-process by any
/// test in this harness. What is covered here is the part that is genuinely fragile and
/// genuinely testable: continuation lifecycle, response plumbing, download relocation, temp-file
/// cleanup, and isolation between concurrent transfers.
final class BackgroundTransferServiceTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeSUT() -> BackgroundTransferService {
        BackgroundTransferService(session: MockURLProtocol.makeSession())
    }

    private func writeTempBody(_ contents: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bts-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("body.bin")
        try contents.write(to: url)
        return url
    }

    private func okResponse(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private var testRequest: URLRequest {
        URLRequest(url: URL(string: "https://example.test/api/v1/drive/files/upload")!)
    }

    // MARK: - Mode

    func test_foregroundMode_reportsItselfAsNotBackground() {
        XCTAssertFalse(makeSUT().isBackgroundSession)
    }

    // MARK: - Upload

    func test_upload_returnsResponseBodyAndStatus() async throws {
        MockURLProtocol.requestHandler = { [self] request in
            (okResponse(request), Data(#"{"ok":true}"#.utf8))
        }
        let sut = makeSUT()
        let bodyFile = try writeTempBody(Data("payload".utf8))

        let (data, http) = try await sut.upload(request: testRequest, fromFile: bodyFile)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"ok":true}"#)
    }

    func test_upload_sendsTheFileContentsAsTheRequestBody() async throws {
        MockURLProtocol.requestHandler = { [self] request in (okResponse(request), Data()) }
        let sut = makeSUT()
        let payload = Data("the exact bytes that must reach the server".utf8)
        let bodyFile = try writeTempBody(payload)

        _ = try await sut.upload(request: testRequest, fromFile: bodyFile)

        XCTAssertEqual(MockURLProtocol.lastRequestBody, payload)
    }

    func test_upload_surfacesNonSuccessStatusToCaller_ratherThanThrowing() async throws {
        // The service is transport-level; interpreting 4xx/5xx belongs to E2EEUploader, which
        // needs the status code to distinguish permanent from retryable failures.
        MockURLProtocol.requestHandler = { [self] request in (okResponse(request, status: 500), Data()) }
        let sut = makeSUT()
        let bodyFile = try writeTempBody(Data("x".utf8))

        let (_, http) = try await sut.upload(request: testRequest, fromFile: bodyFile)

        XCTAssertEqual(http.statusCode, 500)
    }

    func test_upload_throwsTransportError_onNetworkFailure() async throws {
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let sut = makeSUT()
        let bodyFile = try writeTempBody(Data("x".utf8))

        do {
            _ = try await sut.upload(request: testRequest, fromFile: bodyFile)
            XCTFail("Expected TransferError.transportError")
        } catch let error as TransferError {
            guard case .transportError = error else {
                return XCTFail("Unexpected TransferError: \(error)")
            }
        }
    }

    func test_upload_deletesTheBodyFileOnSuccess() async throws {
        MockURLProtocol.requestHandler = { [self] request in (okResponse(request), Data()) }
        let sut = makeSUT()
        let bodyFile = try writeTempBody(Data("x".utf8))

        _ = try await sut.upload(request: testRequest, fromFile: bodyFile)

        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyFile.path),
                       "The multipart body file must not outlive the transfer — it holds ciphertext of user data")
    }

    func test_upload_deletesTheBodyFileOnFailure() async throws {
        MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }
        let sut = makeSUT()
        let bodyFile = try writeTempBody(Data("x".utf8))

        _ = try? await sut.upload(request: testRequest, fromFile: bodyFile)

        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyFile.path))
    }

    func test_upload_keepsTheBodyFile_whenCallerOptsOutOfCleanup() async throws {
        MockURLProtocol.requestHandler = { [self] request in (okResponse(request), Data()) }
        let sut = makeSUT()
        let bodyFile = try writeTempBody(Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: bodyFile.deletingLastPathComponent()) }

        _ = try await sut.upload(request: testRequest, fromFile: bodyFile,
                                 deleteBodyFileOnCompletion: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyFile.path))
    }

    // MARK: - Concurrency

    func test_concurrentUploads_doNotCrossTalk() async throws {
        // Each task keeps its own continuation, response buffer, and progress handler keyed by
        // taskIdentifier. If that bookkeeping leaked, this is where it would show up.
        MockURLProtocol.requestHandler = { [self] request in
            let marker = request.value(forHTTPHeaderField: "X-Marker") ?? "none"
            return (okResponse(request), Data(marker.utf8))
        }
        let sut = makeSUT()

        var requestA = testRequest
        requestA.setValue("alpha", forHTTPHeaderField: "X-Marker")
        var requestB = testRequest
        requestB.setValue("bravo", forHTTPHeaderField: "X-Marker")

        let fileA = try writeTempBody(Data("a".utf8))
        let fileB = try writeTempBody(Data("b".utf8))

        async let responseA = sut.upload(request: requestA, fromFile: fileA)
        async let responseB = sut.upload(request: requestB, fromFile: fileB)

        let (dataA, _) = try await responseA
        let (dataB, _) = try await responseB

        XCTAssertEqual(String(data: dataA, encoding: .utf8), "alpha")
        XCTAssertEqual(String(data: dataB, encoding: .utf8), "bravo")
    }

    func test_manySequentialUploads_allResumeExactlyOnce() async throws {
        // A double-resumed continuation is a hard crash and a never-resumed one is a permanent
        // hang, so "ran 20 times and returned 20 results" is the assertion that matters.
        MockURLProtocol.requestHandler = { [self] request in (okResponse(request), Data("ok".utf8)) }
        let sut = makeSUT()

        var completed = 0
        for _ in 0..<20 {
            let file = try writeTempBody(Data("x".utf8))
            _ = try await sut.upload(request: testRequest, fromFile: file)
            completed += 1
        }

        XCTAssertEqual(completed, 20)
    }

    // MARK: - Download

    func test_download_returnsAReadableFileWithTheResponseBody() async throws {
        let payload = Data("encrypted blob contents".utf8)
        MockURLProtocol.requestHandler = { [self] request in (okResponse(request), payload) }
        let sut = makeSUT()

        let (fileURL, http) = try await sut.download(request: testRequest)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "URLSession deletes its own temp location the moment didFinishDownloadingTo returns; the file must already have been relocated")
        XCTAssertEqual(try Data(contentsOf: fileURL), payload)
    }

    func test_download_surfacesNonSuccessStatusToCaller() async throws {
        MockURLProtocol.requestHandler = { [self] request in (okResponse(request, status: 404), Data()) }
        let sut = makeSUT()

        let (fileURL, http) = try await sut.download(request: testRequest)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        XCTAssertEqual(http.statusCode, 404)
    }

    func test_download_throwsTransportError_onNetworkFailure() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let sut = makeSUT()

        do {
            _ = try await sut.download(request: testRequest)
            XCTFail("Expected TransferError.transportError")
        } catch let error as TransferError {
            guard case .transportError = error else {
                return XCTFail("Unexpected TransferError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_download_relocatesEachTransferToItsOwnDirectory() async throws {
        MockURLProtocol.requestHandler = { [self] request in (okResponse(request), Data("body".utf8)) }
        let sut = makeSUT()

        let (first, _) = try await sut.download(request: testRequest)
        let (second, _) = try await sut.download(request: testRequest)
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent(),
                          "Two concurrent downloads must never collide on the same path")
    }

    // MARK: - Small requests

    func test_dataFor_runsOnTheForegroundSession() async throws {
        // Background sessions reject data tasks outright, which is why the sealed-key JSON
        // calls have their own path.
        MockURLProtocol.requestHandler = { [self] request in
            (okResponse(request), Data(#"{"encrypted_file_key":"abc"}"#.utf8))
        }
        let sut = makeSUT()

        let (data, response) = try await sut.data(for: testRequest)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("abc"))
    }

    // MARK: - Background relaunch handler

    func test_handleBackgroundEvents_storesTheHandlerWithoutInvokingItImmediately() {
        // The handler must only fire from urlSessionDidFinishEvents; calling it on receipt
        // would tell UIKit the app is done before the delegate callbacks have been replayed.
        let sut = makeSUT()
        var called = false

        sut.handleBackgroundEvents { called = true }

        XCTAssertFalse(called)
    }
}
