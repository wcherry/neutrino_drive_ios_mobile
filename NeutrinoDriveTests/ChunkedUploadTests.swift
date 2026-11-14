import XCTest
import Sodium
import NeutrinoCore
import NeutrinoCrypto
@testable import NeutrinoDrive

/// NEB1 uploads behind `e2eeChunkedWrites` (neutrino#318), and the flag cache that drives them.
final class ChunkedUploadTests: XCTestCase {

    private func seedKeysAndToken() {
        let pub = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        KeychainService.save(pub, forKey: SharedStorage.Keys.publicKey)
        KeychainService.save("unused-private-key", forKey: SharedStorage.Keys.privateKey)
        KeychainService.save("1", forKey: SharedStorage.Keys.keyVersion)
        KeychainService.save(TestJWT.make(), forKey: SharedStorage.Keys.accessToken)
    }

    override func tearDown() {
        KeychainService.delete(forKey: SharedStorage.Keys.publicKey)
        KeychainService.delete(forKey: SharedStorage.Keys.privateKey)
        KeychainService.delete(forKey: SharedStorage.Keys.keyVersion)
        KeychainService.delete(forKey: SharedStorage.Keys.accessToken)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeSUT(chunked: Bool) -> E2EEUploader {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var sut = E2EEUploader(transferService: BackgroundTransferService(session: MockURLProtocol.makeSession()),
                               pendingKeys: PendingUploadKeyStore(fileURL: url))
        sut.writesChunked = { chunked }
        return sut
    }

    private func plaintext(_ length: Int) -> Data {
        Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
    }

    /// The file part's bytes: between the blank line after its headers and the closing boundary.
    private func filePart(of body: Data, boundary: String) throws -> Data {
        let marker = Data("name=\"file\"".utf8)
        let start = try XCTUnwrap(body.range(of: marker))
        let blank = try XCTUnwrap(body.range(of: Data("\r\n\r\n".utf8), in: start.upperBound..<body.endIndex))
        let tail = Data("\r\n--\(boundary)--\r\n".utf8)
        XCTAssertTrue(body.suffix(tail.count) == tail, "the body ends with the closing boundary")
        return body.subdata(in: blank.upperBound..<(body.endIndex - tail.count))
    }

    private func boundary(of request: URLRequest) throws -> String {
        let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        return String(try XCTUnwrap(type.components(separatedBy: "boundary=").last))
    }

    // MARK: - Writer

    func testWithTheFlagOnTheFilePartIsNEB1() async throws {
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let size = 2 * DriveFileCrypto.neb1DefaultChunkSize + 11
        let prepared = try await makeSUT(chunked: true).prepare(
            data: plaintext(size), fileName: "IMG_1.MOV", mimeType: "video/quicktime", parentFolderID: nil)
        defer { try? FileManager.default.removeItem(at: prepared.bodyFileURL) }

        let body = try Data(contentsOf: prepared.bodyFileURL)
        let blob = try filePart(of: body, boundary: boundary(of: prepared.request))
        XCTAssertTrue(blob.starts(with: DriveFileCrypto.neb1Magic))
        let header = Array(blob.prefix(20))
        XCTAssertEqual(Array(header[4..<8]), [0x01, 0x01, 0x00, 0x00], "version 1, alg 1, reserved 0")
        XCTAssertEqual(header[8..<12].reduce(0) { $0 << 8 | Int($1) }, DriveFileCrypto.neb1DefaultChunkSize)
        XCTAssertEqual(header[12..<20].reduce(0) { $0 << 8 | Int($1) }, size)
        XCTAssertEqual(blob.count, 44 + size + 17 * 3)
        let text = String(decoding: body.prefix(2000), as: UTF8.self)
        XCTAssertTrue(text.contains(#"name="encrypted_file_key""#), "the scalars still precede the file part")
    }

    func testWithTheFlagOffTheFilePartIsV0AsBefore() async throws {
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let prepared = try await makeSUT(chunked: false).prepare(
            data: plaintext(5000), fileName: "a.jpg", mimeType: "image/jpeg", parentFolderID: nil)
        defer { try? FileManager.default.removeItem(at: prepared.bodyFileURL) }

        let blob = try filePart(of: Data(contentsOf: prepared.bodyFileURL),
                                boundary: boundary(of: prepared.request))
        XCTAssertEqual(blob.count, 24 + 5000 + 17, "one push")
    }

    func testTheNEB1BodyDecryptsBackToThePlaintext() throws {
        let dek = DriveFileCrypto.newDEK()
        let plain = plaintext(10_000)
        let head = E2EEUploader.multipartHead(fileName: "a", mimeType: "image/jpeg", parentFolderID: nil,
                                              encryptedMetadata: "m", thumbnailBase64: nil, boundary: "B")
        let tail = E2EEUploader.multipartTail(boundary: "B")
        let (url, length) = try E2EEUploader.writeNEB1Body(plaintext: plain, dek: dek, head: head, tail: tail)
        defer { try? FileManager.default.removeItem(at: url) }

        let body = try Data(contentsOf: url)
        XCTAssertEqual(body.count, length)
        XCTAssertTrue(body.starts(with: head))
        let blob = body.subdata(in: head.count..<(body.count - tail.count))
        XCTAssertEqual(try DriveFileCrypto.decrypt(blob, dek: dek), plain)
    }

    func testTheV0BodyIsHeadThenCiphertextThenTail() {
        let head = E2EEUploader.multipartHead(fileName: "a", mimeType: "image/jpeg", parentFolderID: "F",
                                              encryptedMetadata: "m", thumbnailBase64: "T", boundary: "B")
        let body = E2EEUploader.buildMultipartBody(encryptedData: Data("CIPHER".utf8), fileName: "a",
                                                   mimeType: "image/jpeg", parentFolderID: "F",
                                                   encryptedMetadata: "m", thumbnailBase64: "T", boundary: "B")
        XCTAssertEqual(body, head + Data("CIPHER".utf8) + E2EEUploader.multipartTail(boundary: "B"))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).hasSuffix("CIPHER\r\n--B--\r\n"))
    }

    // MARK: - Flag cache

    private func scratchDefaults() throws -> UserDefaults {
        let name = "ChunkedUploadTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    func testTheFlagIsCachedFromTheServersMap() throws {
        let defaults = try scratchDefaults()
        try RemoteFeatureFlags.apply(Data(#"{"teamSpaces":true,"e2eeChunkedWrites":true}"#.utf8), to: defaults)
        XCTAssertTrue(E2EEUploader.chunkedWritesEnabled(defaults))
        try RemoteFeatureFlags.apply(Data(#"{"e2eeChunkedWrites":false}"#.utf8), to: defaults)
        XCTAssertFalse(E2EEUploader.chunkedWritesEnabled(defaults))
    }

    func testAServerWithoutTheFlagMeansOff() throws {
        let defaults = try scratchDefaults()
        defaults.set(true, forKey: E2EEUploader.chunkedWritesKey)
        try RemoteFeatureFlags.apply(Data(#"{"teamSpaces":true}"#.utf8), to: defaults)
        XCTAssertFalse(E2EEUploader.chunkedWritesEnabled(defaults))
    }

    func testAnUnreadableResponseKeepsTheCachedValue() throws {
        let defaults = try scratchDefaults()
        defaults.set(true, forKey: E2EEUploader.chunkedWritesKey)
        XCTAssertThrowsError(try RemoteFeatureFlags.apply(Data("not json".utf8), to: defaults))
        XCTAssertTrue(E2EEUploader.chunkedWritesEnabled(defaults))
    }

    func testOffByDefault() throws {
        XCTAssertFalse(E2EEUploader.chunkedWritesEnabled(try scratchDefaults()))
    }
}
