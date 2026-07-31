import Foundation
import os.log

// MARK: - MediaStreamError

enum MediaStreamError: LocalizedError, Equatable {
    case notAuthenticated
    case noEncryptionKey
    case serverError(statusCode: Int)
    /// The server answered a `Range` request with `200 OK` and the whole body.
    case rangeNotSupported
    case malformedContentRange(String)
    case ciphertextTooShort(bytes: Int64)
    case shortRead(expected: Int, got: Int)
    case networkError(String)
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:   return "You are not signed in."
        case .noEncryptionKey:    return "No encryption key found."
        case .serverError(let c): return "Server error (\(c))."
        case .rangeNotSupported:
            return "This server does not support range requests, so the file cannot be streamed. "
                 + "Download it instead."
        case .malformedContentRange(let v):
            return "The server returned an unreadable Content-Range header (\(v))."
        case .ciphertextTooShort(let n):
            return "The encrypted file is too short to be valid (\(n) bytes)."
        case .shortRead(let e, let g):
            return "The server returned \(g) bytes where \(e) were requested."
        case .networkError(let m): return "A network error occurred: \(m)"
        case .notPrepared:         return "Internal error: the media stream was not prepared."
        }
    }
}

// MARK: - EncryptedMediaStream

/// Fetches and decrypts **byte ranges** of an E2EE file on demand, so video and audio can play
/// without downloading and decrypting the whole thing first.
///
/// This is the piece that makes `mvp.md`'s "Large File Streaming" possible at all. See
/// `SecretStreamCrypto` for the finding that permits it: the stored format is a single
/// secretstream message, whose body is plain ChaCha20 counter mode and therefore seekable, even
/// though libsodium's public `pull` is one-shot.
///
/// Deliberately plain and free of AVFoundation: it takes a plaintext byte range and returns
/// plaintext bytes. `EncryptedMediaResourceLoader` is the thin `AVAssetResourceLoaderDelegate`
/// that adapts it. Keeping them apart is what lets the range arithmetic, the `Range` header
/// construction, and the 206 handling be unit-tested against `MockURLProtocol` — none of which
/// is reachable through an `AVAsset`.
///
/// # These bytes are NOT authenticated
///
/// One Poly1305 MAC covers the whole message, so verifying any byte requires reading every
/// byte — which is precisely what a seeking reader does not do. Everything returned here is
/// decrypted but **unverified**.
///
/// I considered verifying the MAC over whatever contiguous prefix the player happened to read,
/// and decided against shipping it. AVFoundation does not read an MP4 front to back: it asks
/// for the content length, then the `moov` atom — which in a non-faststart file sits at the
/// *end* — and only then seeks back to the media data. A "contiguous prefix" therefore almost
/// never completes for real media, so the check would report `unverified` essentially always
/// while implying that verification was happening. A verification feature that silently never
/// fires is worse than none, because it invites the reader to believe a guarantee that is not
/// there.
///
/// What protects the user instead is scope. `StreamingPlaybackService` uses this path **only**
/// for transient playback of large media, and only when `FeatureFlags.largeFileStreaming` is
/// on. Every path that persists or exports plaintext — download, offline caching, File Provider
/// materialization, drag-out — runs the authenticated
/// `SecretStreamCrypto.decrypt(fileAt:to:key:)` instead, which verifies the MAC and fails
/// closed. Small files are downloaded in full rather than streamed, so the trade is taken only
/// where it actually buys something.
///
/// The residual risk, stated plainly: while streaming, a malicious or compromised server can
/// feed the media decoder bytes that were not the bytes uploaded, and nothing here will notice.
/// A deployment unwilling to accept that should set `FeatureFlags.largeFileStreaming = false`,
/// which restores full-download playback with full authentication.
///
/// Closing the gap properly needs a **chunked** secretstream — many independently authenticated
/// messages — which is a wire-format change requiring backend and web agreement, and is
/// recorded as a follow-up rather than attempted here.
final class EncryptedMediaStream {

    // MARK: - Metadata

    struct Metadata: Equatable {
        /// Length of the decrypted file — what AVFoundation must be told.
        let plaintextLength: Int64
        /// Length of the stored blob, including the 41-byte envelope.
        let ciphertextLength: Int64
    }

    // MARK: - Dependencies

    private let fileID: String
    private let versionID: String?
    private let session: URLSession
    private let baseURL: String
    private let token: String
    private let dek: [UInt8]

    private var reader: SecretStreamCrypto.RandomAccessReader?
    private(set) var metadata: Metadata?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "EncryptedMediaStream")

    init(fileID: String,
         versionID: String? = nil,
         dek: [UInt8],
         token: String,
         baseURL: String,
         session: URLSession) {
        self.fileID = fileID
        self.versionID = versionID
        self.dek = dek
        self.token = token
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Prepare

    /// Fetches the 24-byte secretstream header and learns the total size, in **one** ranged
    /// request. The total comes from `Content-Range`'s `/total` field rather than a separate
    /// metadata call, so preparing a stream costs a single round trip of 24 bytes.
    @discardableResult
    func prepare() async throws -> Metadata {
        let headerRange: Range<Int64> = 0..<Int64(SecretStreamCrypto.headerBytes)
        let (headerData, totalBytes) = try await fetchRange(headerRange)

        guard headerData.count == SecretStreamCrypto.headerBytes else {
            throw MediaStreamError.shortRead(expected: SecretStreamCrypto.headerBytes,
                                             got: headerData.count)
        }
        guard let plaintextLength = SecretStreamCrypto.plaintextLength(forCiphertextBytes: totalBytes) else {
            throw MediaStreamError.ciphertextTooShort(bytes: totalBytes)
        }

        do {
            reader = try SecretStreamCrypto.RandomAccessReader(
                header: [UInt8](headerData),
                key: dek,
                plaintextLength: plaintextLength,
                // Stated explicitly at the call site, which is the point of the parameter.
                acknowledgingLackOfAuthentication: true
            )
        } catch {
            throw MediaStreamError.noEncryptionKey
        }

        let meta = Metadata(plaintextLength: plaintextLength, ciphertextLength: totalBytes)
        metadata = meta
        logger.debug("prepared \(self.fileID, privacy: .public): \(plaintextLength) plaintext bytes")
        return meta
    }

    // MARK: - Read

    /// Decrypted plaintext for `length` bytes starting at `offset`.
    ///
    /// Clamps to the end of the file rather than failing, because AVFoundation routinely asks
    /// for more than remains and expects a short answer, not an error.
    func read(plaintextOffset offset: Int64, length: Int64) async throws -> Data {
        guard let reader, let metadata else { throw MediaStreamError.notPrepared }
        guard offset >= 0, offset < metadata.plaintextLength, length > 0 else { return Data() }

        let clamped = min(length, metadata.plaintextLength - offset)
        let (range, discard) = try reader.ciphertextRange(forPlaintextOffset: offset,
                                                          length: clamped)
        let (slice, _) = try await fetchRange(range)

        let expected = Int(range.upperBound - range.lowerBound)
        guard slice.count == expected else {
            throw MediaStreamError.shortRead(expected: expected, got: slice.count)
        }

        let alignedOffset = range.lowerBound - Int64(SecretStreamCrypto.headerBytes + 1)
        return try reader.decrypt(bodySlice: slice,
                                  atAlignedPlaintextOffset: alignedOffset,
                                  discardPrefix: discard)
    }

    // MARK: - Networking

    /// Issues one HTTP `Range` request and returns the body plus the total resource size.
    ///
    /// **Fails closed on 200.** A server (or an intermediate proxy) that ignores `Range` answers
    /// with `200 OK` and the entire body. Accepting that would mean treating byte 0 of the file
    /// as byte `offset` of the range, decrypting with the wrong counter, and handing AVFoundation
    /// silent garbage — and it would also reintroduce the whole-file buffering this feature
    /// exists to remove. So a 200 where 206 was requested is an error, not a fallback.
    ///
    /// The backend serves blobs through `actix_files::NamedFile::into_response`, which
    /// implements `Range` and 206 natively (`src/drive/storage/api.rs`), so this should not
    /// trigger against a correctly deployed server.
    private func fetchRange(_ range: Range<Int64>) async throws -> (Data, Int64) {
        let path = E2EEDownloader.blobPath(fileID: fileID, versionID: versionID)
        guard let url = URL(string: baseURL + path) else {
            throw MediaStreamError.serverError(statusCode: 0)
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // HTTP byte ranges are inclusive at both ends; `Range` is half-open.
        req.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                     forHTTPHeaderField: "Range")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw MediaStreamError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MediaStreamError.serverError(statusCode: 0)
        }
        guard http.statusCode != 200 else { throw MediaStreamError.rangeNotSupported }
        guard http.statusCode == 206 else {
            throw MediaStreamError.serverError(statusCode: http.statusCode)
        }

        guard let contentRange = http.value(forHTTPHeaderField: "Content-Range") else {
            throw MediaStreamError.malformedContentRange("(absent)")
        }
        guard let total = Self.totalBytes(fromContentRange: contentRange) else {
            throw MediaStreamError.malformedContentRange(contentRange)
        }
        return (data, total)
    }

    /// Parses the total size out of `bytes <start>-<end>/<total>`.
    ///
    /// Returns nil for the `*/total` and `bytes x-y/*` forms — an unknown total is not something
    /// this can proceed on, since the plaintext length is derived from it.
    static func totalBytes(fromContentRange value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(total)
    }
}
