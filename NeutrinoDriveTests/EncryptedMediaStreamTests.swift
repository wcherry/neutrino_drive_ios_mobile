import XCTest
import Sodium
@testable import NeutrinoDrive

/// Tests for the ranged-fetch half of large-file streaming.
///
/// The crypto is proven in `SecretStreamCryptoTests`; what is proven here is the part that
/// talks to a server — that the right `Range` header goes out for a given plaintext range, that
/// the bytes coming back are decrypted at the right counter, and that a server which ignores
/// `Range` is treated as an error rather than silently mis-decoded.
///
/// `AVAssetResourceLoaderDelegate` itself is not exercised: driving one requires a real
/// `AVPlayer` decoding real media, which is a runtime check (verification doc), not a unit
/// test. That separation is why the range logic lives in `EncryptedMediaStream` rather than in
/// the delegate.
final class EncryptedMediaStreamTests: XCTestCase {

    private let sodium = Sodium()
    private let fileID = "file-123"
    private let host = "https://drive.example.com"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func encrypt(_ plaintext: Data) throws -> (blob: Data, key: [UInt8]) {
        let xcss = sodium.secretStream.xchacha20poly1305
        let key = xcss.key()
        let push = try XCTUnwrap(xcss.initPush(secretKey: key))
        let header = push.header()
        let ct = try XCTUnwrap(push.push(message: Array(plaintext), tag: .FINAL))
        return (Data(header + ct), key)
    }

    /// Serves `blob` the way `actix_files::NamedFile` does: honouring `Range` with a 206 and a
    /// `Content-Range` header. Records every Range header seen so tests can assert on them.
    private func serve(_ blob: Data, capturing ranges: RangeRecorder? = nil) {
        MockURLProtocol.requestHandler = { request in
            guard let rangeHeader = request.value(forHTTPHeaderField: "Range") else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: nil, headerFields: nil)!
                return (response, blob)
            }
            ranges?.record(rangeHeader)
            let spec = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            let lower = Int(parts[0]) ?? 0
            let upper = Int(parts[1]) ?? (blob.count - 1)
            let slice = blob.subdata(in: lower..<min(upper + 1, blob.count))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes \(lower)-\(upper)/\(blob.count)"]
            )!
            return (response, slice)
        }
    }

    final class RangeRecorder {
        private(set) var headers: [String] = []
        func record(_ h: String) { headers.append(h) }
    }

    private func makeStream(key: [UInt8]) -> EncryptedMediaStream {
        EncryptedMediaStream(fileID: fileID, dek: key, token: "test-token",
                             baseURL: host, session: MockURLProtocol.makeSession())
    }

    // MARK: - Content-Range parsing

    func test_totalBytes_parsesContentRange() {
        XCTAssertEqual(EncryptedMediaStream.totalBytes(fromContentRange: "bytes 0-23/4096"), 4096)
        XCTAssertEqual(EncryptedMediaStream.totalBytes(fromContentRange: "bytes 100-199/100000"), 100_000)
    }

    func test_totalBytes_rejectsUnknownTotal() {
        // `bytes 0-23/*` means the server does not know the size. The plaintext length is
        // derived from the total, so proceeding is not possible.
        XCTAssertNil(EncryptedMediaStream.totalBytes(fromContentRange: "bytes 0-23/*"))
        XCTAssertNil(EncryptedMediaStream.totalBytes(fromContentRange: "garbage"))
    }

    // MARK: - Prepare

    func test_prepare_derivesPlaintextLengthFromContentRange() async throws {
        let plaintext = Data(repeating: 0xAB, count: 5000)
        let (blob, key) = try encrypt(plaintext)
        let recorder = RangeRecorder()
        serve(blob, capturing: recorder)

        let stream = makeStream(key: key)
        let metadata = try await stream.prepare()

        XCTAssertEqual(metadata.plaintextLength, 5000)
        XCTAssertEqual(metadata.ciphertextLength, Int64(blob.count))
        // Exactly one request, for exactly the 24 header bytes — preparing a stream must not
        // cost a whole-file fetch, which is the entire point of the feature.
        XCTAssertEqual(recorder.headers, ["bytes=0-23"])
    }

    func test_prepare_throwsWhenServerIgnoresRange() async throws {
        let (blob, key) = try encrypt(Data(repeating: 1, count: 1000))
        MockURLProtocol.requestHandler = { request in
            // A proxy that strips Range answers 200 with the whole body.
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, blob)
        }

        let stream = makeStream(key: key)
        do {
            _ = try await stream.prepare()
            XCTFail("expected rangeNotSupported")
        } catch {
            XCTAssertEqual(error as? MediaStreamError, .rangeNotSupported)
        }
    }

    func test_prepare_throwsOnServerError() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let stream = makeStream(key: sodium.secretStream.xchacha20poly1305.key())
        do {
            _ = try await stream.prepare()
            XCTFail("expected serverError")
        } catch {
            XCTAssertEqual(error as? MediaStreamError, .serverError(statusCode: 404))
        }
    }

    func test_prepare_rejectsBlobTooShortToBeCiphertext() async throws {
        let tiny = Data(repeating: 0, count: 30)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes 0-23/30"]
            )!
            return (response, tiny.prefix(24))
        }
        let stream = makeStream(key: sodium.secretStream.xchacha20poly1305.key())
        do {
            _ = try await stream.prepare()
            XCTFail("expected ciphertextTooShort")
        } catch {
            XCTAssertEqual(error as? MediaStreamError, .ciphertextTooShort(bytes: 30))
        }
    }

    // MARK: - Ranged reads

    /// The core claim of the feature: an arbitrary range of a large file decrypts correctly
    /// without ever fetching the whole thing.
    func test_read_returnsCorrectPlaintextForArbitraryRanges() async throws {
        // Pseudo-random but reproducible, so a wrong-counter bug cannot coincidentally match.
        let plaintext = Data((0..<20_000).map { UInt8(($0 &* 31 &+ 7) % 251) })
        let (blob, key) = try encrypt(plaintext)
        serve(blob)

        let stream = makeStream(key: key)
        try await stream.prepare()

        for (offset, length) in [(0, 100), (1, 63), (64, 64), (65, 500), (10_000, 1000), (19_999, 1)] {
            let got = try await stream.read(plaintextOffset: Int64(offset), length: Int64(length))
            let expected = plaintext.subdata(in: offset..<(offset + length))
            XCTAssertEqual(got, expected, "range \(offset)+\(length) decrypted incorrectly")
        }
    }

    /// A read must fetch only the bytes it needs (block-aligned), not the file.
    func test_read_requestsOnlyTheAlignedCiphertextRange() async throws {
        let (blob, key) = try encrypt(Data(repeating: 7, count: 20_000))
        let recorder = RangeRecorder()
        serve(blob, capturing: recorder)

        let stream = makeStream(key: key)
        try await stream.prepare()
        _ = try await stream.read(plaintextOffset: 100, length: 50)

        // Body starts at blob byte 25. Plaintext 100 aligns down to 64 → 25+64 = 89.
        // Plaintext end 150 → 25+150 = 175, inclusive upper bound 174.
        XCTAssertEqual(recorder.headers, ["bytes=0-23", "bytes=89-174"])
    }

    /// AVFoundation routinely asks for more than remains; a short answer is correct, an error
    /// is not.
    func test_read_clampsRequestPastEndOfFile() async throws {
        let plaintext = Data(repeating: 0x5A, count: 1000)
        let (blob, key) = try encrypt(plaintext)
        serve(blob)

        let stream = makeStream(key: key)
        try await stream.prepare()

        let got = try await stream.read(plaintextOffset: 900, length: 50_000)
        XCTAssertEqual(got.count, 100)
        XCTAssertEqual(got, plaintext.suffix(100))
    }

    func test_read_returnsEmptyForOffsetAtOrPastEnd() async throws {
        let (blob, key) = try encrypt(Data(repeating: 3, count: 500))
        serve(blob)
        let stream = makeStream(key: key)
        try await stream.prepare()

        let atEnd = try await stream.read(plaintextOffset: 500, length: 10)
        XCTAssertTrue(atEnd.isEmpty)
        let past = try await stream.read(plaintextOffset: 9999, length: 10)
        XCTAssertTrue(past.isEmpty)
    }

    func test_read_beforePrepare_throwsNotPrepared() async throws {
        let stream = makeStream(key: sodium.secretStream.xchacha20poly1305.key())
        do {
            _ = try await stream.read(plaintextOffset: 0, length: 10)
            XCTFail("expected notPrepared")
        } catch {
            XCTAssertEqual(error as? MediaStreamError, .notPrepared)
        }
    }

    /// A truncated 206 must fail loudly. Responding with fewer bytes than asked for and
    /// decrypting anyway would shift every subsequent byte against the keystream.
    func test_read_throwsOnShortResponse() async throws {
        let (blob, key) = try encrypt(Data(repeating: 9, count: 5000))
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            let rangeHeader = request.value(forHTTPHeaderField: "Range")!
            let spec = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            let lower = Int(parts[0])!, upper = Int(parts[1])!
            var slice = blob.subdata(in: lower..<min(upper + 1, blob.count))
            if callCount > 1 { slice = slice.dropLast(10) }   // truncate the data read only
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes \(lower)-\(upper)/\(blob.count)"]
            )!
            return (response, slice)
        }

        let stream = makeStream(key: key)
        try await stream.prepare()
        do {
            _ = try await stream.read(plaintextOffset: 0, length: 1000)
            XCTFail("expected shortRead")
        } catch {
            guard case .shortRead = (error as? MediaStreamError) else {
                return XCTFail("expected shortRead, got \(error)")
            }
        }
    }

    // MARK: - Streaming policy

    func test_shouldStream_requiresMediaTypeAndSizeAboveThreshold() {
        let big = StreamingPlaybackService.streamingThresholdBytes + 1
        let small = StreamingPlaybackService.streamingThresholdBytes - 1

        XCTAssertEqual(StreamingPlaybackService.shouldStream(mimeType: "video/mp4", sizeBytes: big),
                       FeatureFlags.largeFileStreaming)
        XCTAssertEqual(StreamingPlaybackService.shouldStream(mimeType: "audio/mpeg", sizeBytes: big),
                       FeatureFlags.largeFileStreaming)

        // Below the threshold the full authenticated download is preferred.
        XCTAssertFalse(StreamingPlaybackService.shouldStream(mimeType: "video/mp4", sizeBytes: small))
        // Not media.
        XCTAssertFalse(StreamingPlaybackService.shouldStream(mimeType: "application/pdf", sizeBytes: big))
        // Unknown size must fall back to downloading rather than guess towards the
        // unauthenticated path.
        XCTAssertFalse(StreamingPlaybackService.shouldStream(mimeType: "video/mp4", sizeBytes: nil))
        XCTAssertFalse(StreamingPlaybackService.shouldStream(mimeType: nil, sizeBytes: big))
    }

    func test_isStreamableMedia_matchesVideoAndAudioOnly() {
        XCTAssertTrue(StreamingPlaybackService.isStreamableMedia(mimeType: "video/quicktime"))
        XCTAssertTrue(StreamingPlaybackService.isStreamableMedia(mimeType: "AUDIO/WAV"))
        XCTAssertFalse(StreamingPlaybackService.isStreamableMedia(mimeType: "image/png"))
        XCTAssertFalse(StreamingPlaybackService.isStreamableMedia(mimeType: nil))
    }

    /// AVFoundation needs a UTType identifier, not a MIME type; handing it the MIME string
    /// produces an asset with no tracks and an opaque failure.
    func test_resourceLoader_mapsMIMETypeToUTType() {
        XCTAssertEqual(EncryptedMediaResourceLoader.utTypeIdentifier(forMIMEType: "video/mp4"),
                       "public.mpeg-4")
        XCTAssertEqual(EncryptedMediaResourceLoader.utTypeIdentifier(forMIMEType: "audio/mpeg"),
                       "public.mp3")
        // Unknown types fall back rather than crashing.
        XCTAssertEqual(EncryptedMediaResourceLoader.utTypeIdentifier(forMIMEType: "x/nonsense"),
                       "public.data")
    }

    /// The custom scheme is what makes AVFoundation delegate instead of loading the URL itself.
    func test_resourceLoader_buildsCustomSchemeURL() throws {
        let url = try XCTUnwrap(EncryptedMediaResourceLoader.loaderURL(forFileID: "abc"))
        XCTAssertEqual(url.scheme, EncryptedMediaResourceLoader.scheme)
        XCTAssertNotEqual(url.scheme, "https",
                          "an https URL would be loaded by AVFoundation directly, bypassing decryption")
    }
}
