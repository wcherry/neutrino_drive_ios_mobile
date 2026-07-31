import Foundation
import Clibsodium

// MARK: - SecretStreamError

enum SecretStreamError: LocalizedError, Equatable {
    case ciphertextTooShort(bytes: Int64)
    case invalidKey
    case invalidHeader
    /// The Poly1305 tag did not match. The plaintext has been discarded.
    case authenticationFailed
    case misalignedOffset(offset: Int64)
    case rangeOutOfBounds
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .ciphertextTooShort(let n):
            return "The encrypted file is too short to be valid (\(n) bytes)."
        case .invalidKey:      return "The decryption key is not a valid 32-byte key."
        case .invalidHeader:   return "The encrypted file's header is malformed."
        case .authenticationFailed:
            return "The file failed its integrity check and may have been tampered with."
        case .misalignedOffset(let o):
            return "Internal error: unaligned random-access offset \(o)."
        case .rangeOutOfBounds: return "Internal error: requested range lies outside the file."
        case .ioError(let m):  return "Failed to read or write file data: \(m)"
        }
    }
}

// MARK: - SecretStreamCrypto

/// Constant-memory and random-access decryption for the ciphertext format this product
/// already uses. **This is not a new format and not new cryptography** — it is libsodium's
/// own `crypto_secretstream_xchacha20poly1305` construction, decrypted incrementally instead
/// of in one allocation, producing byte-identical plaintext.
///
/// ## Why this type exists
///
/// Both clients encrypt a whole file as a *single* secretstream message:
///
/// - iOS — `E2EEUploader.upload`: `filePushStream.push(message: Array(plainData), tag: .FINAL)`
/// - Web — `web/packages/e2e-crypto/src/crypto.ts`:
///   `crypto_secretstream_xchacha20poly1305_push(state, plaintext, null, TAG_FINAL)`
///
/// giving `[24-byte header][1-byte encrypted tag][N-byte body][16-byte Poly1305 MAC]`.
///
/// libsodium's public `..._pull` is one-shot per message: it needs the entire ciphertext
/// resident and emits the entire plaintext resident. Peak memory is therefore ~2x the file.
/// In the app that is wasteful; in the File Provider extension it is a jetsam kill, which is
/// why PR #9 had to cap materialization at 64 MB.
///
/// It is tempting to conclude from "one monolithic message" that incremental decryption is
/// impossible and only a format change could fix it. **That conclusion is wrong**, and acting
/// on it would leave a fixable bug unfixed. The secretstream construction is a documented
/// composition, and its message body is
///
///     crypto_stream_chacha20_ietf_xor_ic(m, nonce, ic: 2, subkey)
///
/// — a pure counter-mode stream cipher. Plaintext byte `i` depends only on ciphertext byte `i`
/// and the keystream block at counter `2 + i/64`. So the body can be decrypted in any order,
/// in any size chunk, in constant memory.
///
/// ## What can and cannot be done — precisely
///
/// | Property | Status |
/// |---|---|
/// | Constant-memory sequential decrypt | Possible, and **fully authenticated** — Poly1305 has a streaming API. |
/// | Random access to an arbitrary byte range | **Possible** — ChaCha20 is seekable. |
/// | Authenticating a range without reading the whole message | **Impossible** — one MAC covers everything. |
///
/// The last row is a property of AEAD-over-one-message in general, not a mistake in this
/// codebase. Fixing it needs a *chunked* secretstream (many messages, each authenticated),
/// which is a wire-format change requiring backend and web agreement. Out of scope here and
/// recorded as a follow-up in the plan document.
///
/// ## The security boundary this type is designed around
///
/// `decrypt(...)` is authenticated and fails closed: on a MAC mismatch the plaintext is
/// deleted and an error is thrown, so unverified bytes never reach a caller.
/// ``RandomAccessReader`` is **not** authenticated and says so in its name, its documentation,
/// and its initializer. The rule the app enforces:
///
/// > Plaintext written to disk, materialized for another app, exported, or made available
/// > offline is ALWAYS produced by the authenticated path. The unauthenticated random-access
/// > path is used only for transient media playback, behind `FeatureFlags.largeFileStreaming`.
///
/// ## Why the tests matter more than usual
///
/// A divergence from libsodium here would not fail any build and would not fail any request —
/// it would hand callers plausible garbage, or worse, accept tampered ciphertext.
/// `SecretStreamCryptoTests` therefore encrypts with `Sodium().secretStream` (literally what
/// `E2EEUploader` uses) and asserts this code reproduces the plaintext byte for byte across
/// sizes that straddle the 64-byte block and the chunk boundary, and asserts that flipping any
/// byte of the tag, body, or MAC is rejected. If those fail, nothing here is safe to ship.
enum SecretStreamCrypto {

    // MARK: - Format Constants

    /// `crypto_secretstream_xchacha20poly1305_HEADERBYTES`
    static let headerBytes = 24
    /// `crypto_secretstream_xchacha20poly1305_KEYBYTES`
    static let keyBytes = 32
    /// `crypto_onetimeauth_poly1305_BYTES`
    static let macBytes = 16
    /// `crypto_secretstream_xchacha20poly1305_ABYTES` — the 1-byte tag plus the MAC.
    static let overheadBytes = 1 + 16

    /// Total non-payload bytes in a stored blob: header + tag + MAC.
    static let envelopeBytes = headerBytes + overheadBytes  // 41

    /// ChaCha20 block size. Every random-access offset must be a multiple of this.
    static let blockBytes = 64

    /// The block counter at which the message body begins. Counter 0 produces the Poly1305
    /// one-time key and counter 1 encrypts the tag byte, so the payload starts at 2.
    private static let bodyInitialCounter: UInt32 = 2

    /// Read/write granularity for the streaming decrypt. A multiple of `blockBytes`, which is
    /// what keeps every chunk boundary on a ChaCha20 block boundary.
    static let defaultChunkBytes = 1 << 20  // 1 MiB

    // MARK: - Plaintext / Ciphertext Size

    /// The plaintext length of a blob of `ciphertextBytes`, or nil if it is too short to be one.
    static func plaintextLength(forCiphertextBytes ciphertextBytes: Int64) -> Int64? {
        let n = ciphertextBytes - Int64(envelopeBytes)
        return n >= 0 ? n : nil
    }

    // MARK: - Derived Context

    /// The per-message subkey and nonce derived from the header, mirroring
    /// `crypto_secretstream_xchacha20poly1305_init_pull`:
    ///
    /// ```c
    /// crypto_core_hchacha20(state->k, header, k, NULL);
    /// counter_reset(state);                       // 4-byte LE counter := 1
    /// memcpy(STATE_INONCE(state), header + 16, 8);
    /// ```
    struct Context {
        /// The HChaCha20-derived subkey (32 bytes).
        let subkey: [UInt8]
        /// The 12-byte ChaCha20-IETF nonce: `[LE32 message counter = 1][header[16..<24]]`.
        let nonce: [UInt8]

        /// The Poly1305 one-time key — keystream block 0.
        fileprivate let polyKey: [UInt8]
        /// Keystream block 1, which masks the tag byte and is also fed to the MAC.
        fileprivate let tagKeystream: [UInt8]
    }

    static func context(header: [UInt8], key: [UInt8]) throws -> Context {
        guard key.count == keyBytes else { throw SecretStreamError.invalidKey }
        guard header.count == headerBytes else { throw SecretStreamError.invalidHeader }

        var subkey = [UInt8](repeating: 0, count: keyBytes)
        let rc = subkey.withUnsafeMutableBufferPointer { out in
            header.withUnsafeBufferPointer { hp in
                key.withUnsafeBufferPointer { kp in
                    crypto_core_hchacha20(out.baseAddress!, hp.baseAddress!, kp.baseAddress!, nil)
                }
            }
        }
        guard rc == 0 else { throw SecretStreamError.invalidHeader }

        // [4-byte LE counter = 1][8-byte inonce from header[16..<24]]
        var nonce = [UInt8](repeating: 0, count: 12)
        nonce[0] = 1
        for i in 0..<8 { nonce[4 + i] = header[16 + i] }

        // Blocks 0 and 1 in one call: block 0 is the Poly1305 key, block 1 masks the tag byte.
        var keystream = [UInt8](repeating: 0, count: 2 * blockBytes)
        _ = keystream.withUnsafeMutableBufferPointer { out in
            nonce.withUnsafeBufferPointer { np in
                subkey.withUnsafeBufferPointer { kp in
                    crypto_stream_chacha20_ietf(out.baseAddress!,
                                                UInt64(2 * blockBytes),
                                                np.baseAddress!,
                                                kp.baseAddress!)
                }
            }
        }

        return Context(subkey: subkey,
                       nonce: nonce,
                       polyKey: Array(keystream[0..<keyBytes]),
                       tagKeystream: Array(keystream[blockBytes..<(2 * blockBytes)]))
    }

    // MARK: - Authenticated Streaming Decrypt (file → file)

    /// Decrypt `sourceURL` into `destinationURL` in constant memory, verifying the Poly1305
    /// MAC over the whole message before the result is allowed to exist.
    ///
    /// Peak memory is `chunkBytes`, independent of file size — a 4 GB file costs the same as a
    /// 4 MB one. That is the property that retires the jetsam risk and the File Provider's
    /// 64 MB cap.
    ///
    /// **Fails closed.** On a MAC mismatch the partially written destination is deleted before
    /// the error is thrown, so a caller can never be handed unverified plaintext by mistake.
    ///
    /// - Returns: the plaintext byte count.
    @discardableResult
    static func decrypt(fileAt sourceURL: URL,
                        to destinationURL: URL,
                        key: [UInt8],
                        chunkBytes: Int = defaultChunkBytes,
                        progress: ((Double) -> Void)? = nil) throws -> Int64 {

        guard key.count == keyBytes else { throw SecretStreamError.invalidKey }

        let totalBytes = fileSize(at: sourceURL) ?? 0
        guard let bodyLength = plaintextLength(forCiphertextBytes: totalBytes) else {
            throw SecretStreamError.ciphertextTooShort(bytes: totalBytes)
        }

        let source: FileHandle
        do { source = try FileHandle(forReadingFrom: sourceURL) }
        catch { throw SecretStreamError.ioError(error.localizedDescription) }
        defer { try? source.close() }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let destination: FileHandle
        do { destination = try FileHandle(forWritingTo: destinationURL) }
        catch { throw SecretStreamError.ioError(error.localizedDescription) }

        // Any failure past this point must not leave readable plaintext behind.
        var succeeded = false
        defer {
            try? destination.close()
            if !succeeded { try? FileManager.default.removeItem(at: destinationURL) }
        }

        guard let headerData = try readExactly(headerBytes + 1, from: source) else {
            throw SecretStreamError.ciphertextTooShort(bytes: totalBytes)
        }
        let ctx = try context(header: Array(headerData[0..<headerBytes]), key: key)
        let encryptedTagByte = headerData[headerBytes]

        var mac = MACAccumulator(context: ctx, encryptedTagByte: encryptedTagByte)

        let alignedChunk = max(blockBytes, (chunkBytes / blockBytes) * blockBytes)
        var processed: Int64 = 0

        while processed < bodyLength {
            let want = Int(min(Int64(alignedChunk), bodyLength - processed))
            guard let cipherChunk = try readExactly(want, from: source) else {
                throw SecretStreamError.ciphertextTooShort(bytes: totalBytes)
            }

            // MAC covers the *ciphertext*, so accumulate before decrypting.
            mac.update(cipherChunk)

            let plainChunk = try decryptBody(cipherChunk,
                                             context: ctx,
                                             atPlaintextOffset: processed)
            do { try destination.write(contentsOf: plainChunk) }
            catch { throw SecretStreamError.ioError(error.localizedDescription) }

            processed += Int64(want)
            if bodyLength > 0 { progress?(Double(processed) / Double(bodyLength)) }
        }

        guard let storedMAC = try readExactly(macBytes, from: source) else {
            throw SecretStreamError.ciphertextTooShort(bytes: totalBytes)
        }
        guard mac.verify(against: storedMAC, bodyLength: bodyLength) else {
            throw SecretStreamError.authenticationFailed
        }

        succeeded = true
        progress?(1)
        return bodyLength
    }

    // MARK: - Authenticated Decrypt (memory → memory)

    /// In-memory equivalent of ``decrypt(fileAt:to:key:chunkBytes:progress:)``, running the
    /// **same** accumulator and the same body decrypt so the two can never disagree.
    ///
    /// Provided for small payloads and for tests. Prefer the file variant for anything a user
    /// might actually upload.
    static func decrypt(ciphertext: Data, key: [UInt8]) throws -> Data {
        guard key.count == keyBytes else { throw SecretStreamError.invalidKey }
        let total = Int64(ciphertext.count)
        guard let bodyLength = plaintextLength(forCiphertextBytes: total) else {
            throw SecretStreamError.ciphertextTooShort(bytes: total)
        }

        let bytes = [UInt8](ciphertext)
        let ctx = try context(header: Array(bytes[0..<headerBytes]), key: key)
        let encryptedTagByte = bytes[headerBytes]

        let bodyStart = headerBytes + 1
        let bodyEnd = bodyStart + Int(bodyLength)
        let body = Data(bytes[bodyStart..<bodyEnd])
        let storedMAC = Data(bytes[bodyEnd..<(bodyEnd + macBytes)])

        var mac = MACAccumulator(context: ctx, encryptedTagByte: encryptedTagByte)
        mac.update(body)
        guard mac.verify(against: storedMAC, bodyLength: bodyLength) else {
            throw SecretStreamError.authenticationFailed
        }

        return try decryptBody(body, context: ctx, atPlaintextOffset: 0)
    }

    // MARK: - Body Decryption

    /// XOR a span of the message body with the ChaCha20 keystream at the correct counter.
    ///
    /// `plaintextOffset` must be a multiple of ``blockBytes`` — the counter is
    /// `2 + offset / 64` and a fractional block has no representation. Callers wanting an
    /// arbitrary offset align down via ``RandomAccessReader``.
    static func decryptBody(_ cipherBody: Data,
                            context ctx: Context,
                            atPlaintextOffset plaintextOffset: Int64) throws -> Data {
        guard plaintextOffset % Int64(blockBytes) == 0 else {
            throw SecretStreamError.misalignedOffset(offset: plaintextOffset)
        }
        guard !cipherBody.isEmpty else { return Data() }

        let blockIndex = plaintextOffset / Int64(blockBytes)
        let counter = UInt64(bodyInitialCounter) + UInt64(blockIndex)
        guard counter <= UInt64(UInt32.max) else { throw SecretStreamError.rangeOutOfBounds }

        var out = [UInt8](repeating: 0, count: cipherBody.count)
        let rc = out.withUnsafeMutableBufferPointer { outP in
            cipherBody.withUnsafeBytes { (inP: UnsafeRawBufferPointer) -> Int32 in
                ctx.nonce.withUnsafeBufferPointer { np in
                    ctx.subkey.withUnsafeBufferPointer { kp in
                        crypto_stream_chacha20_ietf_xor_ic(
                            outP.baseAddress!,
                            inP.bindMemory(to: UInt8.self).baseAddress!,
                            UInt64(cipherBody.count),
                            np.baseAddress!,
                            UInt32(counter),
                            kp.baseAddress!
                        )
                    }
                }
            }
        }
        guard rc == 0 else { throw SecretStreamError.invalidKey }
        return Data(out)
    }

    // MARK: - Random Access (UNAUTHENTICATED)

    /// Decrypts arbitrary byte ranges of a file's plaintext without reading the whole message.
    ///
    /// # This reader does not authenticate anything
    ///
    /// A single Poly1305 MAC covers the entire message, so verifying *any* byte requires
    /// reading *every* byte. A reader that seeks by definition has not done that. Bytes
    /// returned here are therefore decrypted but **unverified**: a malicious server or a
    /// corrupted store could flip bits undetected, and in an end-to-end-encrypted product the
    /// server is exactly who the threat model says not to trust.
    ///
    /// That is an acceptable trade for *transient media playback* and nothing else. It must
    /// never be used to write a file to disk, materialize an item for another app, produce an
    /// export, or populate the offline cache — all of which use
    /// ``SecretStreamCrypto/decrypt(fileAt:to:key:chunkBytes:progress:)``.
    ///
    /// ``EncryptedMediaStreamLoader`` narrows the exposure by verifying the MAC over whatever
    /// contiguous prefix it has actually seen; see its documentation for what that does and
    /// does not guarantee.
    struct RandomAccessReader {

        let context: Context
        /// Plaintext length, i.e. the body length.
        let plaintextLength: Int64

        /// - Parameter acknowledgingLackOfAuthentication: has no effect beyond forcing the
        ///   call site to state, in source, that the caller knows these bytes are unverified.
        ///   Cheap, and it means a future refactor cannot adopt this reader silently.
        init(header: [UInt8],
             key: [UInt8],
             plaintextLength: Int64,
             acknowledgingLackOfAuthentication: Bool) throws {
            precondition(acknowledgingLackOfAuthentication,
                         "RandomAccessReader returns unverified plaintext; see its documentation.")
            self.context = try SecretStreamCrypto.context(header: header, key: key)
            self.plaintextLength = plaintextLength
        }

        /// The ciphertext byte range that must be fetched to satisfy a plaintext range,
        /// expanded down to a ChaCha20 block boundary.
        ///
        /// Returns the byte range **within the stored blob** (so it already accounts for the
        /// 24-byte header and 1-byte tag), plus how many leading plaintext bytes to discard.
        func ciphertextRange(forPlaintextOffset offset: Int64,
                             length: Int64) throws -> (range: Range<Int64>, discardPrefix: Int) {
            guard offset >= 0, length >= 0, offset + length <= plaintextLength else {
                throw SecretStreamError.rangeOutOfBounds
            }
            let alignedOffset = (offset / Int64(blockBytes)) * Int64(blockBytes)
            let discard = Int(offset - alignedOffset)
            let end = min(offset + length, plaintextLength)
            let bodyStart = Int64(headerBytes + 1)
            return (range: (bodyStart + alignedOffset)..<(bodyStart + end), discardPrefix: discard)
        }

        /// Decrypt a ciphertext span previously identified by ``ciphertextRange(forPlaintextOffset:length:)``.
        ///
        /// - Parameter alignedPlaintextOffset: the block-aligned plaintext offset the span
        ///   starts at, i.e. `range.lowerBound - 25`.
        func decrypt(bodySlice: Data,
                     atAlignedPlaintextOffset alignedPlaintextOffset: Int64,
                     discardPrefix: Int) throws -> Data {
            let plain = try SecretStreamCrypto.decryptBody(bodySlice,
                                                           context: context,
                                                           atPlaintextOffset: alignedPlaintextOffset)
            guard discardPrefix <= plain.count else { throw SecretStreamError.rangeOutOfBounds }
            return plain.dropFirst(discardPrefix)
        }
    }

    // MARK: - MAC Accumulator

    /// Streaming Poly1305 over a single secretstream message, mirroring the update order in
    /// `crypto_secretstream_xchacha20poly1305_pull`:
    ///
    /// ```c
    /// crypto_onetimeauth_poly1305_init(&st, block0);        // keystream block 0
    /// update(ad, adlen); update(_pad0, (0x10 - adlen) & 0xf);
    /// block = keystream_block1; block[0] = in[0];
    /// update(block, 64);
    /// update(c, mlen);
    /// update(_pad0, (0x10 - (64 + mlen)) & 0xf);
    /// update(LE64(adlen), 8);
    /// update(LE64(64 + mlen), 8);
    /// final(mac);
    /// ```
    ///
    /// `ad` is empty in this format, so both `ad` updates are zero-length no-ops and are
    /// omitted rather than written as calls that do nothing.
    struct MACAccumulator {

        private var state = crypto_onetimeauth_poly1305_state()
        private var accumulated: Int64 = 0

        init(context ctx: Context, encryptedTagByte: UInt8) {
            withUnsafeMutablePointer(to: &state) { sp in
                ctx.polyKey.withUnsafeBufferPointer { kp in
                    _ = crypto_onetimeauth_poly1305_init(sp, kp.baseAddress!)
                }
            }
            // The 64-byte tag block as libsodium authenticates it: the *ciphertext* tag byte
            // followed by bytes 1..<64 of keystream block 1.
            var tagBlock = ctx.tagKeystream
            tagBlock[0] = encryptedTagByte
            update(Data(tagBlock), countsTowardBody: false)
        }

        mutating func update(_ data: Data) { update(data, countsTowardBody: true) }

        private mutating func update(_ data: Data, countsTowardBody: Bool) {
            guard !data.isEmpty else { return }
            withUnsafeMutablePointer(to: &state) { sp in
                data.withUnsafeBytes { (bp: UnsafeRawBufferPointer) in
                    _ = crypto_onetimeauth_poly1305_update(
                        sp, bp.bindMemory(to: UInt8.self).baseAddress!, UInt64(data.count)
                    )
                }
            }
            if countsTowardBody { accumulated += Int64(data.count) }
        }

        /// Finalize and compare in constant time.
        ///
        /// - Parameter bodyLength: the message length, used for the trailing length field.
        ///   Asserted against what was actually fed in, so a caller that skipped a chunk gets
        ///   a failure rather than a wrong MAC that happens to match.
        mutating func verify(against storedMAC: Data, bodyLength: Int64) -> Bool {
            guard accumulated == bodyLength, storedMAC.count == macBytes else { return false }

            // The padding length libsodium actually uses, which is **not** the RFC 8439 rule.
            //
            // `crypto_secretstream_xchacha20poly1305_pull` writes:
            //
            //     update(&st, _pad0, (0x10 - (sizeof block) + mlen) & 0xf);
            //
            // With `sizeof block == 64` and unsigned arithmetic that is `(mlen - 48) mod 16`,
            // and since 48 is a multiple of 16 it reduces to **`mlen mod 16`** — not the
            // `(16 - mlen mod 16) mod 16` that padding-to-a-boundary would give. The two agree
            // only when `mlen mod 16` is 0 or 8, which is exactly why an implementation that
            // assumes the standard rule passes on round sizes and fails on everything else.
            //
            // Poly1305 tolerates a non-block-aligned final chunk, so this is a quirk of the
            // construction rather than a defect — but it has to be reproduced exactly, and
            // `test_decryptData_matchesLibsodium_acrossBlockBoundaries` is what pins it down.
            let padding = Int(bodyLength % 16)
            if padding > 0 { update(Data(repeating: 0, count: padding), countsTowardBody: false) }

            update(littleEndian64(0), countsTowardBody: false)                       // adlen
            update(littleEndian64(UInt64(Int64(blockBytes) + bodyLength)),           // 64 + mlen
                   countsTowardBody: false)

            var computed = [UInt8](repeating: 0, count: macBytes)
            withUnsafeMutablePointer(to: &state) { sp in
                _ = computed.withUnsafeMutableBufferPointer { out in
                    crypto_onetimeauth_poly1305_final(sp, out.baseAddress!)
                }
            }

            return computed.withUnsafeBufferPointer { cp in
                storedMAC.withUnsafeBytes { (sp: UnsafeRawBufferPointer) -> Bool in
                    sodium_memcmp(cp.baseAddress!,
                                  sp.bindMemory(to: UInt8.self).baseAddress!,
                                  macBytes) == 0
                }
            }
        }

        private func littleEndian64(_ value: UInt64) -> Data {
            var v = value.littleEndian
            return Data(bytes: &v, count: 8)
        }
    }

    // MARK: - IO Helpers

    static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        if let size = attrs[.size] as? Int64 { return size }
        if let size = attrs[.size] as? UInt64 { return Int64(size) }
        if let size = attrs[.size] as? NSNumber { return size.int64Value }
        return nil
    }

    /// Reads exactly `count` bytes, or returns nil if the file ended early. `FileHandle.read`
    /// is permitted to return a short read, and treating one as end-of-file would silently
    /// truncate the MAC input.
    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: count - buffer.count) }
            catch { throw SecretStreamError.ioError(error.localizedDescription) }
            guard let chunk, !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
        return buffer
    }
}
