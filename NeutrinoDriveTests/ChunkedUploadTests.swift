import XCTest
import Sodium
import NeutrinoCore
import NeutrinoCrypto
@testable import NeutrinoDrive

/// Every upload body is NEB1 (neutrino#318), from bytes in memory or from a file on disk.
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

    private func makeSUT() -> E2EEUploader {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return E2EEUploader(transferService: BackgroundTransferService(session: MockURLProtocol.makeSession()),
                            pendingKeys: PendingUploadKeyStore(fileURL: url))
    }

    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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

    func testTheFilePartIsNEB1() async throws {
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let size = 2 * DriveFileCrypto.neb1DefaultChunkSize + 11
        let prepared = try await makeSUT().prepare(
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

    func testASmallFileIsOneNEB1Chunk() async throws {
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let prepared = try await makeSUT().prepare(
            data: plaintext(5000), fileName: "a.jpg", mimeType: "image/jpeg", parentFolderID: nil)
        defer { try? FileManager.default.removeItem(at: prepared.bodyFileURL) }

        let blob = try filePart(of: Data(contentsOf: prepared.bodyFileURL),
                                boundary: boundary(of: prepared.request))
        XCTAssertTrue(blob.starts(with: DriveFileCrypto.neb1Magic))
        XCTAssertEqual(blob.count, 44 + 5000 + 17, "one chunk")
    }

    func testAFileSourceIsEncryptedFromDiskAndLeftForTheCaller() async throws {
        seedKeysAndToken()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let plain = plaintext(2 * DriveFileCrypto.neb1DefaultChunkSize + 11)
        let source = try tempFile(plain)
        let prepared = try await makeSUT().prepare(
            source: .file(source), fileName: "IMG_2.MOV", mimeType: "video/quicktime", parentFolderID: nil,
            thumbnailBase64: "T")
        defer { try? FileManager.default.removeItem(at: prepared.bodyFileURL) }

        let blob = try filePart(of: Data(contentsOf: prepared.bodyFileURL),
                                boundary: boundary(of: prepared.request))
        XCTAssertEqual(blob.count, 44 + plain.count + 17 * 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the caller owns the export and discards it")
    }

    func testTheNEB1BodyDecryptsBackToThePlaintextFromEitherSource() throws {
        let dek = DriveFileCrypto.newDEK()
        let plain = plaintext(3 * DriveFileCrypto.neb1DefaultChunkSize + 5)
        let head = E2EEUploader.multipartHead(fileName: "a", mimeType: "image/jpeg", parentFolderID: nil,
                                              encryptedMetadata: "m", thumbnailBase64: nil, boundary: "B")
        let tail = E2EEUploader.multipartTail(boundary: "B")
        for source in [PlaintextSource.data(plain), .file(try tempFile(plain))] {
            let (url, length) = try E2EEUploader.writeNEB1Body(source: source, dek: dek, head: head, tail: tail)
            defer { try? FileManager.default.removeItem(at: url) }

            let body = try Data(contentsOf: url)
            XCTAssertEqual(body.count, length)
            XCTAssertTrue(body.starts(with: head))
            let blob = body.subdata(in: head.count..<(body.count - tail.count))
            XCTAssertEqual(try DriveFileCrypto.decrypt(blob, dek: dek), plain)
        }
    }

    func testAPlaintextSourceReportsItsSizeAndDiscardsOnlyAFile() throws {
        let plain = plaintext(1234)
        let url = try tempFile(plain)
        XCTAssertEqual(PlaintextSource.data(plain).byteCount, 1234)
        XCTAssertEqual(PlaintextSource.file(url).byteCount, 1234)
        XCTAssertEqual(try PlaintextSource.file(url).loadData(), plain)
        PlaintextSource.file(url).discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        PlaintextSource.file(url).discard() // twice is harmless
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
}
