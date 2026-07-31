import Foundation
import AVFoundation
import UniformTypeIdentifiers
import os.log

// MARK: - EncryptedMediaResourceLoader

/// Bridges AVFoundation's resource-loading callbacks to `EncryptedMediaStream`.
///
/// AVFoundation will only ask a delegate for bytes when it cannot fetch the URL itself, so the
/// asset is built against a **custom scheme** (`neutrino-e2ee://`). That is the whole trick:
/// the player thinks it is reading an ordinary seekable file, while every byte it receives has
/// been fetched as a ciphertext range and decrypted in flight.
///
/// Kept deliberately thin. All the range arithmetic, `Range` header construction, and 206
/// handling live in `EncryptedMediaStream`, where they can be unit-tested — an
/// `AVAssetResourceLoaderDelegate` cannot be driven from XCTest without a real `AVPlayer`
/// decoding real media, which is a runtime check rather than a unit test.
///
/// **The bytes this serves are unauthenticated.** See `EncryptedMediaStream` for why, and for
/// the scope rule that keeps the exposure to transient playback.
final class EncryptedMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    /// The scheme that makes AVFoundation delegate to us instead of loading the URL itself.
    static let scheme = "neutrino-e2ee"

    private let stream: EncryptedMediaStream
    private let contentType: String

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "EncryptedMediaResourceLoader")

    /// - Parameter stream: must already have been `prepare()`d, so the content length is known
    ///   by the time AVFoundation asks for it.
    init(stream: EncryptedMediaStream, mimeType: String) {
        self.stream = stream
        self.contentType = Self.utTypeIdentifier(forMIMEType: mimeType)
    }

    /// AVFoundation wants a UTType identifier here, not a MIME type. Handing it
    /// `"video/mp4"` yields an asset that reports no tracks and fails with an opaque error.
    ///
    /// Dynamic types are rejected as well as nil. `UTType(mimeType:)` does not return nil for
    /// an unrecognised MIME type — it synthesises a placeholder like
    /// `dyn.ah62d4rv4gq81up5sr71hg3pssrwu`, which carries no conformance information and is
    /// just as useless to AVFoundation as the raw MIME string would be. Falling back to
    /// `public.data` at least lets the player sniff the container.
    static func utTypeIdentifier(forMIMEType mimeType: String) -> String {
        guard let type = UTType(mimeType: mimeType), !type.isDynamic else {
            return UTType.data.identifier
        }
        return type.identifier
    }

    /// Rewrites an https URL to the custom scheme so the asset routes through this delegate.
    static func loaderURL(forFileID fileID: String) -> URL? {
        URL(string: "\(scheme)://file/\(fileID)")
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource
                        loadingRequest: AVAssetResourceLoadingRequest) -> Bool {

        if let info = loadingRequest.contentInformationRequest {
            guard let metadata = stream.metadata else {
                loadingRequest.finishLoading(with: MediaStreamError.notPrepared)
                return true
            }
            info.contentType = contentType
            info.contentLength = metadata.plaintextLength
            // The claim that lets the player seek at all. It is true because the secretstream
            // body is counter-mode and therefore randomly addressable — see SecretStreamCrypto.
            info.isByteRangeAccessSupported = true
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        // `requestedLength` is capped for an open-ended request; `currentOffset` accounts for
        // bytes already handed over if AVFoundation is resuming a partially-served request.
        let offset = dataRequest.currentOffset
        let remaining = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - offset
        guard remaining > 0 else {
            loadingRequest.finishLoading()
            return true
        }

        Task { [stream, logger] in
            do {
                let data = try await stream.read(plaintextOffset: offset, length: remaining)
                guard !loadingRequest.isCancelled else { return }
                dataRequest.respond(with: data)
                loadingRequest.finishLoading()
            } catch {
                logger.error("range read failed at \(offset): \(error, privacy: .public)")
                guard !loadingRequest.isCancelled else { return }
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // The in-flight Task checks `isCancelled` before responding; nothing else to unwind.
    }
}

// MARK: - StreamingPlaybackService

/// Decides whether a Drive item should be **streamed** or **downloaded**, and builds the
/// `AVPlayerItem` for the streaming case.
///
/// This type is where the security trade described in `EncryptedMediaStream` is actually
/// bounded, so the policy lives in one readable place rather than being spread across call
/// sites.
@MainActor
final class StreamingPlaybackService: ObservableObject {

    /// Files at or below this size are downloaded in full and decrypted with the
    /// **authenticated** path, then played from disk.
    ///
    /// The point of a threshold is that streaming's cost — unverified bytes — should only be
    /// paid where its benefit is real. A 20 MB clip downloads fast enough that skipping the
    /// integrity check buys almost nothing; a 2 GB film is a different matter. 32 MB is a
    /// judgement call, not a measured optimum, and is stated as such.
    nonisolated static let streamingThresholdBytes: Int64 = 32 * 1024 * 1024

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "StreamingPlaybackService")

    private let session: URLSession
    private let downloader: E2EEDownloader
    /// Retained for the lifetime of playback: `AVURLAsset` holds its resource-loader delegate
    /// **weakly**, so dropping this reference makes the player stall on its first range request
    /// with no error worth reading.
    private var activeLoaders: [ObjectIdentifier: EncryptedMediaResourceLoader] = [:]

    init(session: URLSession = .shared, downloader: E2EEDownloader = E2EEDownloader()) {
        self.session = session
        self.downloader = downloader
    }

    // MARK: - Policy

    /// Whether `mimeType` is something AVFoundation can play at all.
    nonisolated static func isStreamableMedia(mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        return mimeType.hasPrefix("video/") || mimeType.hasPrefix("audio/")
    }

    /// The single decision point: stream, or download and play locally.
    ///
    /// Requires all of — the feature flag, a media MIME type, a *known* size, and that size
    /// being above the threshold. An unknown size deliberately falls back to downloading:
    /// guessing wrong towards streaming would take the unauthenticated path for a file that
    /// might be tiny.
    nonisolated static func shouldStream(mimeType: String?, sizeBytes: Int64?) -> Bool {
        guard FeatureFlags.largeFileStreaming else { return false }
        guard isStreamableMedia(mimeType: mimeType) else { return false }
        guard let sizeBytes else { return false }
        return sizeBytes > streamingThresholdBytes
    }

    // MARK: - Player Construction

    /// Builds an `AVPlayerItem` that decrypts ranges on demand.
    ///
    /// Throws rather than silently falling back to a full download, so a caller cannot end up
    /// believing it is streaming when it is not.
    func makeStreamingPlayerItem(fileID: String,
                                 versionID: String? = nil,
                                 mimeType: String) async throws -> AVPlayerItem {

        guard let token = SharedStorage.accessToken() else {
            throw MediaStreamError.notAuthenticated
        }
        let dek = try await downloader.unsealedDEK(fileID: fileID)

        let stream = EncryptedMediaStream(fileID: fileID,
                                          versionID: versionID,
                                          dek: dek,
                                          token: token,
                                          baseURL: SharedStorage.serverHost,
                                          session: session)
        // Prepared *before* the asset is created, so the content-information request that
        // AVFoundation issues first can be answered synchronously from cached metadata.
        try await stream.prepare()

        guard let url = EncryptedMediaResourceLoader.loaderURL(forFileID: fileID) else {
            throw MediaStreamError.serverError(statusCode: 0)
        }
        let asset = AVURLAsset(url: url)
        let loader = EncryptedMediaResourceLoader(stream: stream, mimeType: mimeType)
        asset.resourceLoader.setDelegate(loader, queue: .global(qos: .userInitiated))

        let item = AVPlayerItem(asset: asset)
        activeLoaders[ObjectIdentifier(item)] = loader
        logger.debug("streaming player item ready for \(fileID, privacy: .public)")
        return item
    }

    /// Drops the retained delegate once playback is over.
    func release(item: AVPlayerItem) {
        activeLoaders.removeValue(forKey: ObjectIdentifier(item))
    }
}
