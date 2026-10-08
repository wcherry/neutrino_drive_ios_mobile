import Foundation
import Compression

// MARK: - ZipArchiveReader

/// Reads a zip archive that is already on disk as plaintext — a Drive download (decrypted by
/// `DownloadService`) or an offline copy.
///
/// Written here rather than pulled in as a package because the viewer needs only the reading half
/// of the format, and that half is small: find the central directory at the tail, walk its
/// entries, and inflate one on demand. Inflation is Apple's Compression framework, whose
/// `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) — exactly what a zip entry holds.
///
/// Like the web viewer (`neutrino/web/apps/web/src/lib/zipArchive.ts`), nothing is inflated until
/// it is opened: `init` reads only the central directory, and `extract` seeks to the one entry
/// asked for. Entry names are display names — the viewer never writes an entry under its archive
/// path, so `../` in a name is cosmetic, and `ZipTree` drops it.
///
/// `@unchecked Sendable` because `extract` seeks a shared `FileHandle`: it is safe to hand between
/// threads but not to call concurrently, and `ZipViewerModel` serialises every call on one queue.
final class ZipArchiveReader: @unchecked Sendable {

    // MARK: - Types

    struct Entry: Hashable, Sendable {
        /// The name exactly as the archive records it.
        let rawPath: String
        let isDirectory: Bool
        let isEncrypted: Bool
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let modified: Date?
    }

    enum ZipError: LocalizedError, Equatable {
        case notAZip
        case corrupt
        case encrypted
        case unsupportedMethod(UInt16)
        case tooLarge
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .notAZip:              return "This file is not a valid zip archive."
            case .corrupt:              return "This archive is damaged and can\u{2019}t be read."
            case .encrypted:            return "This file is password-protected and can\u{2019}t be opened here."
            case .unsupportedMethod:    return "This file uses a compression method Drive can\u{2019}t open."
            case .tooLarge:             return "This file is too large to open from the archive."
            case .checksumMismatch:     return "This file is damaged inside the archive."
            }
        }
    }

    // MARK: - Constants

    /// Largest entry `extract` will inflate into memory.
    static let maxExtractBytes: UInt64 = 512 * 1024 * 1024

    private enum Signature {
        static let endOfCentralDirectory: UInt32 = 0x0605_4B50
        static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4B50
        static let zip64Locator: UInt32 = 0x0706_4B50
        static let centralDirectoryHeader: UInt32 = 0x0201_4B50
        static let localFileHeader: UInt32 = 0x0403_4B50
    }

    // MARK: - Properties

    let url: URL
    let entries: [Entry]
    private let handle: FileHandle
    private let fileSize: UInt64

    // MARK: - Init

    init(url: URL) throws {
        self.url = url
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ZipError.notAZip
        }
        let size = try handle.seekToEnd()
        fileSize = size
        entries = try Self.readCentralDirectory(handle: handle, fileSize: size)
    }

    deinit {
        try? handle.close()
    }

    /// Whether a Drive file should open in the zip viewer.
    ///
    /// The extension counts on its own because a zip uploaded from a browser that did not know
    /// the type arrives as `application/octet-stream`. Not a substring match on "zip": that would
    /// take in gzip and bzip2, which are not archives this reader opens.
    static func isZip(mimeType: String?, name: String) -> Bool {
        if mimeType == "application/zip" || mimeType == "application/x-zip-compressed" { return true }
        return (name as NSString).pathExtension.lowercased() == "zip"
    }

    // MARK: - Extraction

    /// Inflates one entry and checks it against the archive's CRC.
    func extract(_ entry: Entry) throws -> Data {
        guard !entry.isDirectory else { throw ZipError.corrupt }
        guard !entry.isEncrypted else { throw ZipError.encrypted }
        guard entry.uncompressedSize <= Self.maxExtractBytes,
              entry.compressedSize <= Self.maxExtractBytes else { throw ZipError.tooLarge }

        // The local header repeats the name and carries its own extra field, whose length can
        // differ from the central directory's — so the data offset is read from here.
        let local = try read(at: entry.localHeaderOffset, count: 30)
        guard local.uint32(at: 0) == Signature.localFileHeader else { throw ZipError.corrupt }
        let nameLength = UInt64(local.uint16(at: 26))
        let extraLength = UInt64(local.uint16(at: 28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard dataOffset + entry.compressedSize <= fileSize else { throw ZipError.corrupt }

        let compressed = try read(at: dataOffset, count: Int(entry.compressedSize))
        let output: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw ZipError.corrupt }
            output = compressed
        case 8:
            output = try Self.inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }

        guard CRC32.checksum(output) == entry.crc32 else { throw ZipError.checksumMismatch }
        return output
    }

    // MARK: - Central Directory

    private static func readCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> [Entry] {
        // The end-of-central-directory record is 22 bytes plus a comment of up to 64 KB, so it
        // sits somewhere in the last 22 + 65535 bytes. Scan backwards for its signature.
        let tailLength = min(fileSize, 22 + 65_535)
        guard tailLength >= 22 else { throw ZipError.notAZip }
        let tailStart = fileSize - tailLength
        let tail = try read(handle: handle, at: tailStart, count: Int(tailLength))

        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail.uint32(at: i) == Signature.endOfCentralDirectory {
                eocd = i
                break
            }
            i -= 1
        }
        guard let eocdIndex = eocd else { throw ZipError.notAZip }

        var entryCount = UInt64(tail.uint16(at: eocdIndex + 10))
        var directorySize = UInt64(tail.uint32(at: eocdIndex + 12))
        var directoryOffset = UInt64(tail.uint32(at: eocdIndex + 16))

        // Zip64: any field at its maximum means the real value is in the zip64 record, found
        // through the locator immediately before the classic record.
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            let locatorIndex = eocdIndex - 20
            guard locatorIndex >= 0, tail.uint32(at: locatorIndex) == Signature.zip64Locator else {
                throw ZipError.corrupt
            }
            let zip64Offset = tail.uint64(at: locatorIndex + 8)
            let record = try read(handle: handle, at: zip64Offset, count: 56)
            guard record.uint32(at: 0) == Signature.zip64EndOfCentralDirectory else { throw ZipError.corrupt }
            entryCount = record.uint64(at: 32)
            directorySize = record.uint64(at: 40)
            directoryOffset = record.uint64(at: 48)
        }

        guard directoryOffset + directorySize <= fileSize, directorySize <= Int.max else {
            throw ZipError.corrupt
        }
        let directory = try read(handle: handle, at: directoryOffset, count: Int(directorySize))

        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(entryCount, 100_000)))
        var cursor = 0
        while cursor + 46 <= directory.count, UInt64(entries.count) < entryCount {
            guard directory.uint32(at: cursor) == Signature.centralDirectoryHeader else { throw ZipError.corrupt }
            let flags = directory.uint16(at: cursor + 8)
            let method = directory.uint16(at: cursor + 10)
            let modTime = directory.uint16(at: cursor + 12)
            let modDate = directory.uint16(at: cursor + 14)
            let crc = directory.uint32(at: cursor + 16)
            var compressedSize = UInt64(directory.uint32(at: cursor + 20))
            var uncompressedSize = UInt64(directory.uint32(at: cursor + 24))
            let nameLength = Int(directory.uint16(at: cursor + 28))
            let extraLength = Int(directory.uint16(at: cursor + 30))
            let commentLength = Int(directory.uint16(at: cursor + 32))
            var localOffset = UInt64(directory.uint32(at: cursor + 42))

            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { throw ZipError.corrupt }

            let nameData = directory.subdata(in: (directory.startIndex + nameStart)..<(directory.startIndex + extraStart))
            // Bit 11 declares UTF-8. Without it the spec says CP437, but in practice that is
            // usually UTF-8 written by a tool that did not set the flag — so try UTF-8 first and
            // fall back to Latin-1, which decodes any byte sequence.
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""

            // Zip64 extended information (header 0x0001) holds only the fields that overflowed,
            // in this fixed order.
            var extraCursor = extraStart
            let extraEnd = extraStart + extraLength
            while extraCursor + 4 <= extraEnd {
                let headerID = directory.uint16(at: extraCursor)
                let size = Int(directory.uint16(at: extraCursor + 2))
                var field = extraCursor + 4
                let fieldEnd = field + size
                guard fieldEnd <= extraEnd else { break }
                if headerID == 0x0001 {
                    if uncompressedSize == 0xFFFF_FFFF, field + 8 <= fieldEnd {
                        uncompressedSize = directory.uint64(at: field); field += 8
                    }
                    if compressedSize == 0xFFFF_FFFF, field + 8 <= fieldEnd {
                        compressedSize = directory.uint64(at: field); field += 8
                    }
                    if localOffset == 0xFFFF_FFFF, field + 8 <= fieldEnd {
                        localOffset = directory.uint64(at: field)
                    }
                }
                extraCursor = fieldEnd
            }

            entries.append(Entry(
                rawPath: name,
                isDirectory: name.hasSuffix("/") || name.hasSuffix("\\"),
                isEncrypted: flags & 0x1 != 0,
                method: method,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset,
                modified: dosDate(date: modDate, time: modTime)
            ))
            cursor = next
        }
        return entries
    }

    /// A zip's MS-DOS timestamp, which carries no zone and so is read as local time.
    static func dosDate(date: UInt16, time: UInt16) -> Date? {
        var components = DateComponents()
        components.year = Int(date >> 9) + 1980
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int(time >> 11)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        guard let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day) else { return nil }
        return Calendar(identifier: .gregorian).date(from: components)
    }

    // MARK: - Inflate

    /// Raw DEFLATE → bytes, refusing to produce more than the archive declared. A header that
    /// understates its size is how a zip bomb gets past a size check, so the cap is enforced
    /// while inflating rather than trusted beforehand.
    static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        // One byte of slack: a stream that writes into it produced more than declared, and an
        // exactly-sized buffer would leave a valid stream unable to report that it had ended.
        var output = Data(count: expectedSize + 1)
        let produced: Int = try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            try output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
                defer { streamPointer.deallocate() }
                guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                        == COMPRESSION_STATUS_OK else { throw ZipError.corrupt }
                defer { compression_stream_destroy(streamPointer) }

                streamPointer.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress
                    ?? UnsafePointer(bitPattern: 1)!
                streamPointer.pointee.src_size = src.count
                streamPointer.pointee.dst_ptr = dst.bindMemory(to: UInt8.self).baseAddress!
                streamPointer.pointee.dst_size = dst.count

                // `process` works in bounded steps and returns OK while it has more to do, so it
                // is called until the stream ends or stops making progress.
                while true {
                    let srcBefore = streamPointer.pointee.src_size
                    let dstBefore = streamPointer.pointee.dst_size
                    let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    switch status {
                    case COMPRESSION_STATUS_END:
                        return dst.count - streamPointer.pointee.dst_size
                    case COMPRESSION_STATUS_OK:
                        // Filled the slack before the stream ended: more data than declared.
                        if streamPointer.pointee.dst_size == 0 { throw ZipError.tooLarge }
                        // Neither side moved: the input ran out mid-stream.
                        if streamPointer.pointee.src_size == srcBefore
                            && streamPointer.pointee.dst_size == dstBefore { throw ZipError.corrupt }
                    default:
                        throw ZipError.corrupt
                    }
                }
            }
        }
        if produced > expectedSize { throw ZipError.tooLarge }
        guard produced == expectedSize else { throw ZipError.corrupt }
        output.removeLast()
        return output
    }

    // MARK: - File Access

    private func read(at offset: UInt64, count: Int) throws -> Data {
        try Self.read(handle: handle, at: offset, count: count)
    }

    private static func read(handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ZipError.corrupt }
            return data
        } catch let error as ZipError {
            throw error
        } catch {
            throw ZipError.corrupt
        }
    }
}

// MARK: - CRC32

/// The CRC-32 (IEEE 802.3) a zip stores for every entry.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Little-endian reads

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }
}

// MARK: - ZipTree

/// The archive as folders: what each folder directly contains, with sizes rolled up.
///
/// Same rules as the web viewer's `buildTree`, so one archive reads the same on both: names are
/// normalised to `/`-separated segments with empty, `.` and `..` dropped; Finder's `__MACOSX/`,
/// `.DS_Store` and `._` files are hidden; folders no entry declares are synthesised; folders sort
/// before files, then by name as Finder sorts them.
struct ZipTree {

    struct Node: Identifiable, Hashable {
        let path: String
        let name: String
        let isDirectory: Bool
        var size: UInt64
        var modified: Date?
        let isEncrypted: Bool
        /// The archive entry behind a file; nil for a folder.
        let entry: ZipArchiveReader.Entry?

        var id: String { path }
    }

    private(set) var nodes: [String: Node] = [:]
    private(set) var children: [String: [Node]] = [:]

    var fileCount: Int { nodes.values.filter { !$0.isDirectory }.count }
    var totalSize: UInt64 { nodes.values.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size } }

    func list(_ folder: String) -> [Node] { children[folder] ?? [] }

    static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    static func isMacOSMetadata(_ path: String) -> Bool {
        if path == "__MACOSX" || path.hasPrefix("__MACOSX/") { return true }
        let base = (path as NSString).lastPathComponent
        return base == ".DS_Store" || base.hasPrefix("._")
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    init(entries: [ZipArchiveReader.Entry]) {
        func ensureFolder(_ path: String) {
            if let existing = nodes[path] {
                // A file and a folder at the same path: the folder is what keeps the rest of the
                // tree reachable, so it wins.
                if !existing.isDirectory {
                    nodes[path] = Node(path: path, name: existing.name, isDirectory: true, size: 0,
                                       modified: existing.modified, isEncrypted: false, entry: nil)
                }
                return
            }
            nodes[path] = Node(path: path, name: (path as NSString).lastPathComponent, isDirectory: true,
                               size: 0, modified: nil, isEncrypted: false, entry: nil)
        }

        for entry in entries {
            let path = Self.normalize(entry.rawPath)
            guard !path.isEmpty, !Self.isMacOSMetadata(path) else { continue }

            var ancestor = Self.parent(of: path)
            while !ancestor.isEmpty {
                ensureFolder(ancestor)
                ancestor = Self.parent(of: ancestor)
            }

            if entry.isDirectory {
                ensureFolder(path)
                if nodes[path]?.modified == nil { nodes[path]?.modified = entry.modified }
                continue
            }
            if nodes[path]?.isDirectory == true { continue }

            // A later entry at the same path replaces an earlier one — what extracting the
            // archive would leave on disk.
            nodes[path] = Node(path: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                               size: entry.uncompressedSize, modified: entry.modified,
                               isEncrypted: entry.isEncrypted, entry: entry)
        }

        // Roll file sizes up into every ancestor folder.
        for node in nodes.values where !node.isDirectory {
            var ancestor = Self.parent(of: node.path)
            while !ancestor.isEmpty {
                nodes[ancestor]?.size += node.size
                ancestor = Self.parent(of: ancestor)
            }
        }

        var grouped: [String: [Node]] = ["": []]
        for node in nodes.values {
            grouped[Self.parent(of: node.path), default: []].append(node)
            if node.isDirectory, grouped[node.path] == nil { grouped[node.path] = [] }
        }
        for key in grouped.keys {
            grouped[key]?.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        children = grouped
    }
}
