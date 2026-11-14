import XCTest
import Compression
@testable import NeutrinoDrive

// MARK: - Fixtures

/// Writes a zip in memory, one entry at a time.
///
/// Built here rather than checked in so the layout each test depends on is visible in the test —
/// and the deflate entries go through Compression's *encoder* while the reader uses its decoder,
/// so a wrong framing assumption on either side shows up as a failure rather than agreeing with
/// itself.
private struct TestZipWriter {

    enum Method { case stored, deflate }

    private var body = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    mutating func add(_ name: String, _ content: Data, method: Method = .deflate,
                      flags: UInt16 = 0x0800, lyingSize: UInt32? = nil) {
        let nameData = Data(name.utf8)
        let payload = method == .stored ? content : Self.deflate(content)
        let crc = CRC32.checksum(content)
        let offset = UInt32(body.count)
        let methodCode: UInt16 = method == .stored ? 0 : 8
        let uncompressed = lyingSize ?? UInt32(content.count)

        var local = Data()
        local.le32(0x0403_4B50); local.le16(20); local.le16(flags); local.le16(methodCode)
        local.le16(0x6000); local.le16(0x5C42) // 12:00:00, 2026-02-02
        local.le32(crc); local.le32(UInt32(payload.count)); local.le32(uncompressed)
        local.le16(UInt16(nameData.count)); local.le16(0)
        local.append(nameData)
        body.append(local)
        body.append(payload)

        var central = Data()
        central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(flags)
        central.le16(methodCode); central.le16(0x6000); central.le16(0x5C42)
        central.le32(crc); central.le32(UInt32(payload.count)); central.le32(uncompressed)
        central.le16(UInt16(nameData.count)); central.le16(0); central.le16(0)
        central.le16(0); central.le16(0); central.le32(0); central.le32(offset)
        central.append(nameData)
        directory.append(central)
        count += 1
    }

    mutating func addFolder(_ name: String) {
        add(name.hasSuffix("/") ? name : name + "/", Data(), method: .stored)
    }

    func data(comment: String = "") -> Data {
        var out = body
        out.append(directory)
        let commentData = Data(comment.utf8)
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0); end.le16(count); end.le16(count)
        end.le32(UInt32(directory.count)); end.le32(UInt32(body.count))
        end.le16(UInt16(commentData.count))
        end.append(commentData)
        out.append(end)
        return out
    }

    static func deflate(_ input: Data) -> Data {
        let capacity = input.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return output.prefix(written)
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}

// MARK: - Tests

final class ZipArchiveReaderTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }
        tempURLs = []
        super.tearDown()
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try data.write(to: url)
        tempURLs.append(url)
        return url
    }

    private func entry(_ reader: ZipArchiveReader, _ path: String) throws -> ZipArchiveReader.Entry {
        try XCTUnwrap(reader.entries.first { $0.rawPath == path })
    }

    // MARK: Reading

    func testReadsStoredAndDeflatedEntries() throws {
        let text = String(repeating: "the quick brown fox ", count: 200)
        var zip = TestZipWriter()
        zip.add("stored.txt", Data("hello".utf8), method: .stored)
        zip.add("dir/deflated.txt", Data(text.utf8))
        let reader = try ZipArchiveReader(url: write(zip.data(comment: "a trailing comment")))

        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertEqual(try reader.extract(entry(reader, "stored.txt")), Data("hello".utf8))
        let deflated = try entry(reader, "dir/deflated.txt")
        XCTAssertEqual(deflated.method, 8)
        XCTAssertLessThan(deflated.compressedSize, deflated.uncompressedSize)
        XCTAssertEqual(try reader.extract(deflated), Data(text.utf8))
    }

    /// Compression inflates in bounded steps; an entry bigger than one step has to be driven to
    /// the end rather than read in a single call (a 280 KB text file from `zip` failed before).
    func testReadsALargeDeflatedEntry() throws {
        let text = (1...60_000).map(String.init).joined(separator: "\n")
        var zip = TestZipWriter()
        zip.add("numbers.txt", Data(text.utf8))
        let reader = try ZipArchiveReader(url: write(zip.data()))
        XCTAssertEqual(try reader.extract(entry(reader, "numbers.txt")), Data(text.utf8))
    }

    func testReadsAnEmptyFile() throws {
        var zip = TestZipWriter()
        zip.add("empty.txt", Data(), method: .stored)
        let reader = try ZipArchiveReader(url: write(zip.data()))
        XCTAssertEqual(try reader.extract(entry(reader, "empty.txt")), Data())
    }

    func testDecodesTheDOSTimestamp() throws {
        var zip = TestZipWriter()
        zip.add("a.txt", Data("a".utf8))
        let reader = try ZipArchiveReader(url: write(zip.data()))
        let modified = try XCTUnwrap(try entry(reader, "a.txt").modified)
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour], from: modified)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 2)
        XCTAssertEqual(parts.day, 2)
        XCTAssertEqual(parts.hour, 12)
    }

    // MARK: Refusals

    func testRejectsSomethingThatIsNotAZip() throws {
        let url = try write(Data("definitely not a zip archive, just some words".utf8))
        XCTAssertThrowsError(try ZipArchiveReader(url: url)) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .notAZip)
        }
    }

    func testRefusesAPasswordProtectedEntry() throws {
        var zip = TestZipWriter()
        zip.add("secret.txt", Data("x".utf8), method: .stored, flags: 0x0801)
        let reader = try ZipArchiveReader(url: write(zip.data()))
        let secret = try entry(reader, "secret.txt")
        XCTAssertTrue(secret.isEncrypted)
        XCTAssertThrowsError(try reader.extract(secret)) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .encrypted)
        }
    }

    /// A header that understates the size is how a zip bomb gets past a size check, so the cap is
    /// enforced while inflating.
    func testRefusesToInflateMoreThanTheHeaderDeclares() throws {
        var zip = TestZipWriter()
        zip.add("bomb.txt", Data(repeating: 0x41, count: 100_000), lyingSize: 10)
        let reader = try ZipArchiveReader(url: write(zip.data()))
        XCTAssertThrowsError(try reader.extract(entry(reader, "bomb.txt"))) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .tooLarge)
        }
    }

    func testDetectsACorruptedEntry() throws {
        var zip = TestZipWriter()
        zip.add("a.txt", Data("abcdefgh".utf8), method: .stored)
        var bytes = zip.data()
        // The stored payload starts after the 30-byte local header and the 5-byte name.
        bytes[35] ^= 0xFF
        let reader = try ZipArchiveReader(url: write(bytes))
        XCTAssertThrowsError(try reader.extract(entry(reader, "a.txt"))) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .checksumMismatch)
        }
    }

    // MARK: isZip

    func testRecognisesAZipByTypeOrName() {
        XCTAssertTrue(ZipArchiveReader.isZip(mimeType: "application/zip", name: "a"))
        XCTAssertTrue(ZipArchiveReader.isZip(mimeType: "application/x-zip-compressed", name: "a"))
        XCTAssertTrue(ZipArchiveReader.isZip(mimeType: "application/octet-stream", name: "Bundle.ZIP"))
        XCTAssertFalse(ZipArchiveReader.isZip(mimeType: "application/gzip", name: "a.tar.gz"))
        XCTAssertFalse(ZipArchiveReader.isZip(mimeType: "application/x-bzip2", name: "a.bz2"))
    }

    // MARK: Tree

    func testTreeSynthesisesFoldersAndRollsUpSizes() throws {
        var zip = TestZipWriter()
        zip.add("src/lib/a.swift", Data(repeating: 1, count: 10))
        zip.add("src/b.swift", Data(repeating: 2, count: 5))
        zip.add("README", Data(repeating: 3, count: 3))
        let tree = ZipTree(entries: try ZipArchiveReader(url: write(zip.data())).entries)

        XCTAssertEqual(tree.list("").map(\.name), ["src", "README"])
        XCTAssertEqual(tree.list("src").map(\.name), ["lib", "b.swift"])
        XCTAssertEqual(tree.nodes["src"]?.size, 15)
        XCTAssertEqual(tree.fileCount, 3)
        XCTAssertEqual(tree.totalSize, 18)
    }

    func testTreeSortsFoldersFirstAndNumbersByValue() throws {
        var zip = TestZipWriter()
        zip.add("file10.txt", Data())
        zip.add("file2.txt", Data())
        zip.add("z/x.txt", Data())
        let tree = ZipTree(entries: try ZipArchiveReader(url: write(zip.data())).entries)
        XCTAssertEqual(tree.list("").map(\.name), ["z", "file2.txt", "file10.txt"])
    }

    func testTreeHidesMacOSMetadataAndNormalisesPaths() throws {
        var zip = TestZipWriter()
        zip.add("a.txt", Data())
        zip.add("__MACOSX/._a.txt", Data())
        zip.add(".DS_Store", Data())
        zip.add("./dot/b.txt", Data())
        zip.add("../escape/c.txt", Data())
        zip.add("win\\d.txt", Data())
        zip.addFolder("empty")
        let tree = ZipTree(entries: try ZipArchiveReader(url: write(zip.data())).entries)

        XCTAssertEqual(tree.list("").map(\.name), ["dot", "empty", "escape", "win", "a.txt"])
        XCTAssertEqual(tree.list("win").map(\.name), ["d.txt"])
        XCTAssertEqual(tree.list("empty"), [])
    }
}
