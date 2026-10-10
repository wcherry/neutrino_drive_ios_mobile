import Foundation
import os.log

// MARK: - TransferError

enum TransferError: LocalizedError {
    /// The task finished without producing an `HTTPURLResponse` — an unusable outcome that
    /// callers must not mistake for a successful transfer.
    case invalidResponse
    case transportError(underlying: Error)
    /// The downloaded file could not be relocated out of the system's short-lived temp
    /// location before URLSession reclaimed it.
    case fileRelocationFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:              return "The server returned an unreadable response."
        case .transportError(let err):      return err.localizedDescription
        case .fileRelocationFailed(let err): return "Failed to save the downloaded file: \(err.localizedDescription)"
        }
    }
}

// MARK: - BackgroundTransferService

/// Runs the app's large blob transfers on a `.background` `URLSessionConfiguration`, so an
/// upload or download that is in flight when iOS suspends the app is handed to the system's
/// transfer daemon and finishes there instead of dying and restarting from zero.
///
/// This is the fix for the risk recorded in `feature-photo-auto-sync.md` under "Known risks".
///
/// ## Why this class is not `@MainActor`
///
/// `URLSessionDelegate` callbacks arrive on the session's `delegateQueue`, which is not the
/// main queue. Hopping to the main actor to resume a continuation that a main-actor caller is
/// awaiting is a deadlock waiting to happen, so all delegate state lives behind an `NSLock`
/// instead and callers are free to be `@MainActor` or not.
///
/// ## What can and cannot run on a background session
///
/// Three constraints from `URLSession` shape everything here:
///
/// 1. **`dataTask` is unsupported** on background sessions. The small JSON calls
///    (`GET`/`PUT` of the sealed file key) therefore stay on a normal session — see
///    ``data(for:)``. They are sub-kilobyte; there is nothing to gain by moving them and a
///    working API to lose.
/// 2. **Upload bodies must come from a file**, never from `Data` or a stream. Callers write
///    the body to a temp file and pass `fromFile:`; this class deletes that file once the
///    task completes, whatever the outcome.
/// 3. **One session per identifier per process.** ``shared`` is the single owner of
///    `com.neutrino.drive.transfers`. Constructing a second session with the same identifier
///    is undefined behaviour.
final class BackgroundTransferService: NSObject {

    // MARK: - Mode

    enum Mode {
        /// A real `.background` session, surviving app suspension.
        ///
        /// `sharedContainerIdentifier` is required for a session an app extension creates:
        /// the system stages the session's files in that App Group container, because the
        /// extension's own container may be gone by the time a transfer finishes.
        case background(identifier: String, sharedContainerIdentifier: String? = nil)
        /// A caller-supplied session. Used by tests (`MockURLProtocol` is never consulted by a
        /// background session, so the real path is untestable in-process) and by the
        /// `FeatureFlags.backgroundTransfers == false` kill switch.
        case foreground(session: URLSession)
    }

    // MARK: - Shared instance

    static let backgroundIdentifier = "com.neutrino.drive.transfers"

    static let shared: BackgroundTransferService = {
        FeatureFlags.backgroundTransfers
            ? BackgroundTransferService(mode: .background(identifier: backgroundIdentifier))
            : BackgroundTransferService(mode: .foreground(session: .shared))
    }()

    // MARK: - The Photos extension's session

    /// The Photos background-upload extension's session. A separate identifier, not
    /// ``backgroundIdentifier``: two processes connected to one background session at the same
    /// time is undefined behaviour.
    static let photosExtensionIdentifier = "com.neutrino.drive.photos.transfers"

    /// The session the Photos extension sends photos on. Created once per extension process.
    static func forPhotosExtension() -> BackgroundTransferService {
        FeatureFlags.backgroundTransfers
            ? BackgroundTransferService(mode: .background(
                identifier: photosExtensionIdentifier,
                sharedContainerIdentifier: SharedStorage.appGroupIdentifier))
            : BackgroundTransferService(mode: .foreground(session: .shared))
    }

    private static let deliveryLock = NSLock()
    /// Sessions of the Photos extension that this app process attached to, to take the results
    /// iOS relaunched it to deliver. See ``attachForDelivery(identifier:completionHandler:)``.
    private static var deliveries: [BackgroundTransferService] = []
    /// What every photo-sync session in this process reports orphaned results to.
    private static var photoSyncOrphanHandler: ((String) -> Void)?

    /// Attaches this process to another process's background session, because iOS relaunched
    /// the app to deliver that session's events.
    ///
    /// When the Photos extension is not running as its transfers finish, iOS hands the events
    /// to the containing app instead, and they reach nobody unless the app connects to a session
    /// with the same identifier. Each finished upload then lands here as an orphan, and the
    /// photo-sync orphan handler collects it. Once the events are replayed the session is let
    /// go, so the next launch of the extension is not sharing it with the app.
    static func attachForDelivery(identifier: String, completionHandler: @escaping () -> Void) {
        deliveryLock.lock()
        let attached = deliveries.first { $0.deliveryIdentifier == identifier && !$0.isInvalidated }
        let service = attached ?? BackgroundTransferService(
            mode: .background(identifier: identifier,
                              sharedContainerIdentifier: SharedStorage.appGroupIdentifier),
            invalidatesAfterEvents: true)
        if attached == nil { deliveries.append(service) }
        let handler = photoSyncOrphanHandler
        deliveryLock.unlock()
        if let handler { service.setOrphanHandler(handler) }
        service.handleBackgroundEvents(completionHandler: completionHandler)
    }

    /// The other processes' sessions attached here, whose results a photo sync retry may need
    /// to collect. Empty except in an app process iOS relaunched for the Photos extension.
    static var attachedDeliveries: [BackgroundTransferService] {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        return deliveries
    }

    /// Sets the orphan handler on ``shared`` and on every delivery session, including ones
    /// attached later. See ``setOrphanHandler(_:)``.
    static func setPhotoSyncOrphanHandler(_ handler: @escaping (String) -> Void) {
        deliveryLock.lock()
        photoSyncOrphanHandler = handler
        let sessions = [shared] + deliveries
        deliveryLock.unlock()
        sessions.forEach { $0.setOrphanHandler(handler) }
    }

    // MARK: - Private state
    //
    // Everything below `stateLock` is touched from both the delegate queue and arbitrary
    // caller tasks. The invariant that matters: a continuation is *removed* from `pending`
    // under the lock before it is resumed, so no code path can resume it twice (a hard crash)
    // and `didCompleteWithError` — which runs for every task regardless of outcome — is the
    // single place responsible for resuming it at all (never leaving one hanging forever).

    private let stateLock = NSLock()
    private var pendingUploads: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]
    private var pendingDownloads: [Int: CheckedContinuation<(URL, HTTPURLResponse), Error>] = [:]
    private var accumulatedData: [Int: Data] = [:]
    private var progressHandlers: [Int: (Double) -> Void] = [:]
    private var relocatedDownloads: [Int: URL] = [:]
    private var bodyFilesToCleanUp: [Int: URL] = [:]

    /// Results for tasks that completed with nobody awaiting them — i.e. the transfer finished
    /// while the app was suspended and iOS relaunched the process to deliver it. Keyed by the
    /// caller-supplied `taskDescription` so a later in-app retry can see the transfer already
    /// succeeded instead of re-uploading the same bytes.
    private var orphanedResults: [String: Result<(Data, HTTPURLResponse), Error>] = [:]

    /// Told the transfer id of every result filed in `orphanedResults`. See ``setOrphanHandler(_:)``.
    private var orphanHandler: ((String) -> Void)?

    /// Set by `AppDelegate` from `handleEventsForBackgroundURLSession`; called once the
    /// session has finished replaying its events.
    private var backgroundEventsCompletionHandler: (() -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "BackgroundTransferService")

    private let mode: Mode

    /// Whether to let go of the session once its events have been replayed. See
    /// ``attachForDelivery(identifier:completionHandler:)``.
    private let invalidatesAfterEvents: Bool
    private var invalidated = false

    private var deliveryIdentifier: String? {
        if case .background(let identifier, _) = mode { return identifier }
        return nil
    }

    private var isInvalidated: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return invalidated
    }

    /// Delegate-less session for small request/response calls. Background sessions cannot run
    /// data tasks at all, so the sealed-key JSON round trips need a separate session regardless
    /// of which mode this service is in.
    private let foregroundSession: URLSession

    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1     // serialise delegate callbacks
        switch mode {
        case .foreground(let provided):
            // Deliberately **not** `provided` itself. A caller-supplied session has no delegate,
            // so none of this class's delegate methods would ever fire and every continuation
            // would hang forever waiting for a completion that cannot arrive. Rebuilding from
            // the same `configuration` preserves everything that matters (including
            // `protocolClasses`, which is how `MockURLProtocol` stays wired up in tests) while
            // making this object the delegate.
            queue.name = "com.neutrino.drive.transfers.foreground.delegate"
            return URLSession(configuration: provided.configuration, delegate: self, delegateQueue: queue)
        case .background(let identifier, let sharedContainerIdentifier):
            let config = URLSessionConfiguration.background(withIdentifier: identifier)
            config.sharedContainerIdentifier = sharedContainerIdentifier
            config.isDiscretionary = false            // user-initiated; do not defer to "a good time"
            config.sessionSendsLaunchEvents = true    // relaunch us to deliver completion
            config.waitsForConnectivity = true
            queue.name = "\(identifier).delegate"
            return URLSession(configuration: config, delegate: self, delegateQueue: queue)
        }
    }()

    // MARK: - Init

    init(mode: Mode, invalidatesAfterEvents: Bool = false) {
        self.mode = mode
        self.invalidatesAfterEvents = invalidatesAfterEvents
        switch mode {
        case .foreground(let session):
            self.foregroundSession = session
        case .background:
            self.foregroundSession = URLSession(configuration: .default)
        }
        super.init()
        _ = session   // instantiate eagerly so a background session reconnects to in-flight tasks
    }

    /// Convenience for tests and for the kill switch.
    convenience init(session: URLSession) {
        self.init(mode: .foreground(session: session))
    }

    var isBackgroundSession: Bool {
        if case .background = mode { return true }
        return false
    }

    // MARK: - Small requests (never background)

    /// Plain request/response for small JSON payloads. Runs on the foreground session because
    /// background sessions do not support data tasks at all.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await foregroundSession.data(for: request)
    }

    // MARK: - Upload

    /// Uploads the contents of `fileURL` as the request body and returns the response.
    ///
    /// - Parameter transferID: a stable identifier for this logical transfer, stored on the
    ///   task's `taskDescription`. If the app is killed and relaunched to deliver this task's
    ///   completion, the result is filed under this ID so a retry can claim it.
    /// - Parameter deleteBodyFileOnCompletion: whether to remove `fileURL` once the task ends.
    ///   Callers that built a temp body file want `true`; the file must survive until the
    ///   task completes, which is why this is not the caller's `defer`.
    func upload(request: URLRequest,
                fromFile fileURL: URL,
                transferID: String = UUID().uuidString,
                deleteBodyFileOnCompletion: Bool = true,
                progress: ((Double) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {

        if let earlier = try await resume(transferID: transferID, progress: progress) {
            // The bytes are already (or still) going up under this identity — sending them a
            // second time would create a second file. The fresh body is not needed.
            if deleteBodyFileOnCompletion { try? FileManager.default.removeItem(at: fileURL) }
            return earlier
        }

        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = transferID

        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            pendingUploads[task.taskIdentifier] = continuation
            if let progress { progressHandlers[task.taskIdentifier] = progress }
            if deleteBodyFileOnCompletion { bodyFilesToCleanUp[task.taskIdentifier] = fileURL }
            stateLock.unlock()
            task.resume()
        }
    }

    // MARK: - Resuming an earlier transfer

    /// Whether a transfer filed under `transferID` already exists: either still running in the
    /// background session, or finished with its result waiting to be claimed.
    ///
    /// Asked *before* a caller spends time rebuilding a body. A background session hands a
    /// relaunched process every task an earlier process left running, so after a relaunch the
    /// upload a queue entry describes may well be in flight already.
    func hasTransfer(transferID: String) async -> Bool {
        stateLock.lock()
        let hasOrphan = orphanedResults[transferID] != nil
        stateLock.unlock()
        if hasOrphan { return true }
        return await runningUploadTask(transferID: transferID) != nil
    }

    /// The outcome of an earlier upload filed under `transferID`, or `nil` when there is none.
    ///
    /// A result that arrived with nobody waiting is handed over at once. A task still running —
    /// typically one an earlier process started and the background session reattached on
    /// launch — is awaited rather than duplicated.
    func resume(transferID: String,
                progress: ((Double) -> Void)? = nil) async throws -> (Data, HTTPURLResponse)? {
        if let claimed = claimOrphanedResult(for: transferID) {
            logger.debug("upload: claimed result completed while suspended (\(transferID, privacy: .public))")
            return try claimed.get()
        }
        guard let task = await runningUploadTask(transferID: transferID) else { return nil }
        logger.debug("upload: reattaching to transfer in flight (\(transferID, privacy: .public))")

        return try await withCheckedThrowingContinuation { continuation in
            // Registered and checked under one lock, against a completion funnel that pops and
            // files an orphan under the same lock: either the task finished first and its result
            // is waiting here, or it has not and will find this continuation. Neither order can
            // leave the continuation hanging.
            stateLock.lock()
            if let finished = orphanedResults.removeValue(forKey: transferID) {
                stateLock.unlock()
                continuation.resume(with: finished)
                return
            }
            pendingUploads[task.taskIdentifier] = continuation
            if let progress { progressHandlers[task.taskIdentifier] = progress }
            stateLock.unlock()
        }
    }

    /// A live upload task carrying `transferID` that nobody in this process is awaiting yet.
    private func runningUploadTask(transferID: String) async -> URLSessionTask? {
        // A session let go after delivering its events has nothing running to reattach to.
        guard !isInvalidated else { return nil }
        let tasks = await session.allTasks
        stateLock.lock()
        defer { stateLock.unlock() }
        return tasks.first { task in
            task.taskDescription == transferID
                && task is URLSessionUploadTask
                && task.state != .completed
                && pendingUploads[task.taskIdentifier] == nil
        }
    }

    // MARK: - Download

    /// Downloads to a file and returns its URL. The file is relocated into a UUID-named temp
    /// directory owned by the caller — `URLSession` deletes the location it hands to
    /// `didFinishDownloadingTo` the moment that delegate method returns, so relocation happens
    /// synchronously inside it and this method only ever sees a durable URL.
    func download(request: URLRequest,
                  transferID: String = UUID().uuidString,
                  progress: ((Double) -> Void)? = nil) async throws -> (URL, HTTPURLResponse) {

        let task = session.downloadTask(with: request)
        task.taskDescription = transferID

        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            pendingDownloads[task.taskIdentifier] = continuation
            if let progress { progressHandlers[task.taskIdentifier] = progress }
            stateLock.unlock()
            task.resume()
        }
    }

    // MARK: - Background relaunch

    /// Stores the completion handler iOS hands us when it relaunches the app to deliver
    /// finished background transfers. Called from `AppDelegate`.
    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        stateLock.lock()
        backgroundEventsCompletionHandler = completionHandler
        stateLock.unlock()
    }

    /// Registers the code told about results that arrive with nobody waiting for them.
    ///
    /// Such a result is held in memory only, so it has to be collected while this process
    /// lives. Being told the moment it lands is what makes that dependable: a relaunch to
    /// deliver background transfers runs no UI and no drain, and a result nobody asks for there
    /// dies with the process — leaving its upload to be sent a second time. Results that landed
    /// before a handler was set are reported at once.
    ///
    /// Called on the session's delegate queue; the handler must hop to wherever its work lives.
    func setOrphanHandler(_ handler: @escaping (String) -> Void) {
        stateLock.lock()
        orphanHandler = handler
        let waiting = Array(orphanedResults.keys)
        stateLock.unlock()
        waiting.forEach(handler)
    }

    private func claimOrphanedResult(for transferID: String) -> Result<(Data, HTTPURLResponse), Error>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return orphanedResults.removeValue(forKey: transferID)
    }

    // MARK: - Completion plumbing

    /// Removes and returns everything registered for `taskIdentifier`, under one lock
    /// acquisition. Returning the continuations here — rather than resuming inside the lock —
    /// is what makes "resumed exactly once" structurally true instead of merely intended.
    ///
    /// When nobody is waiting, the result is filed as an orphan under `orphanID` in the same
    /// lock acquisition. Doing it in a second one would open a gap in which ``resume(transferID:progress:)``
    /// could register a continuation after the pop and before the orphan existed — and wait
    /// forever for a task that had already finished.
    private func popState(
        for taskIdentifier: Int,
        orphanID: String?,
        orphanResult: (Data) -> Result<(Data, HTTPURLResponse), Error>
    ) -> (
        upload: CheckedContinuation<(Data, HTTPURLResponse), Error>?,
        download: CheckedContinuation<(URL, HTTPURLResponse), Error>?,
        data: Data,
        relocated: URL?,
        bodyFile: URL?
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let upload = pendingUploads.removeValue(forKey: taskIdentifier)
        let download = pendingDownloads.removeValue(forKey: taskIdentifier)
        let data = accumulatedData.removeValue(forKey: taskIdentifier) ?? Data()
        let relocated = relocatedDownloads.removeValue(forKey: taskIdentifier)
        let bodyFile = bodyFilesToCleanUp.removeValue(forKey: taskIdentifier)
        progressHandlers.removeValue(forKey: taskIdentifier)
        if upload == nil, download == nil, let orphanID {
            orphanedResults[orphanID] = orphanResult(data)
        }
        return (upload, download, data, relocated, bodyFile)
    }
}

// MARK: - URLSessionDataDelegate

extension BackgroundTransferService: URLSessionDataDelegate {

    /// Upload tasks are data tasks, so their response bodies arrive here rather than as a
    /// completion-handler payload.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateLock.lock()
        accumulatedData[dataTask.taskIdentifier, default: Data()].append(data)
        stateLock.unlock()
    }
}

// MARK: - URLSessionTaskDelegate

extension BackgroundTransferService: URLSessionTaskDelegate {

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        stateLock.lock()
        let handler = progressHandlers[task.taskIdentifier]
        stateLock.unlock()
        handler?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    /// The single completion funnel. Runs for every task — success, HTTP error, transport
    /// failure, cancellation — which is precisely why continuation resumption lives here and
    /// nowhere else.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let wrappedError = error.map { TransferError.transportError(underlying: $0) }
        let http = task.response as? HTTPURLResponse
        // Nobody waiting means this task completed while the app was suspended, or in a process
        // that has since died; its result is kept for whoever asks for it next.
        let state = popState(for: task.taskIdentifier, orphanID: task.taskDescription) { data in
            if let wrappedError { return .failure(wrappedError) }
            guard let http else { return .failure(TransferError.invalidResponse) }
            return .success((data, http))
        }
        if state.upload == nil, state.download == nil, let id = task.taskDescription {
            logger.debug("recorded orphaned transfer result for \(id, privacy: .public)")
            stateLock.lock()
            let handler = orphanHandler
            stateLock.unlock()
            handler?(id)
        }

        if let bodyFile = state.bodyFile {
            try? FileManager.default.removeItem(at: bodyFile)
        }

        if let wrappedError {
            logger.error("task \(task.taskIdentifier) failed: \(wrappedError, privacy: .public)")
            state.upload?.resume(throwing: wrappedError)
            state.download?.resume(throwing: wrappedError)
            return
        }

        guard let http else {
            state.upload?.resume(throwing: TransferError.invalidResponse)
            state.download?.resume(throwing: TransferError.invalidResponse)
            return
        }

        if let upload = state.upload {
            upload.resume(returning: (state.data, http))
            return
        }

        if let download = state.download {
            if let relocated = state.relocated {
                download.resume(returning: (relocated, http))
            } else {
                download.resume(throwing: TransferError.invalidResponse)
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundTransferService: URLSessionDownloadDelegate {

    /// `location` is deleted as soon as this method returns, so the move must happen here and
    /// synchronously. The relocated URL is stashed and handed to the continuation from
    /// `didCompleteWithError`, keeping resumption in one place.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let destinationDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            let destination = destinationDir.appendingPathComponent("transfer.bin")
            try FileManager.default.moveItem(at: location, to: destination)
            stateLock.lock()
            relocatedDownloads[downloadTask.taskIdentifier] = destination
            stateLock.unlock()
        } catch {
            logger.error("failed to relocate downloaded file: \(error, privacy: .public)")
            // Leave `relocatedDownloads` empty; `didCompleteWithError` turns that into
            // `TransferError.invalidResponse` for the awaiting caller.
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        stateLock.lock()
        let handler = progressHandlers[downloadTask.taskIdentifier]
        stateLock.unlock()
        handler?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
}

// MARK: - URLSessionDelegate

extension BackgroundTransferService {

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateLock.lock()
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        let letGo = invalidatesAfterEvents && !invalidated
        if letGo { invalidated = true }
        stateLock.unlock()
        // Lets tasks still running finish rather than cancelling them; the orphans already
        // filed stay in memory for photo sync to collect.
        if letGo { session.finishTasksAndInvalidate() }
        // UIKit requires this on the main queue.
        DispatchQueue.main.async { handler?() }
    }
}
