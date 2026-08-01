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
        case background(identifier: String)
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

    /// Set by `AppDelegate` from `handleEventsForBackgroundURLSession`; called once the
    /// session has finished replaying its events.
    private var backgroundEventsCompletionHandler: (() -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "BackgroundTransferService")

    private let mode: Mode

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
        case .background(let identifier):
            let config = URLSessionConfiguration.background(withIdentifier: identifier)
            config.isDiscretionary = false            // user-initiated; do not defer to "a good time"
            config.sessionSendsLaunchEvents = true    // relaunch us to deliver completion
            config.waitsForConnectivity = true
            queue.name = "\(identifier).delegate"
            return URLSession(configuration: config, delegate: self, delegateQueue: queue)
        }
    }()

    // MARK: - Init

    init(mode: Mode) {
        self.mode = mode
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

        if let claimed = claimOrphanedResult(for: transferID) {
            logger.debug("upload: claimed result completed while suspended (\(transferID, privacy: .public))")
            if deleteBodyFileOnCompletion { try? FileManager.default.removeItem(at: fileURL) }
            return try claimed.get()
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

    private func claimOrphanedResult(for transferID: String) -> Result<(Data, HTTPURLResponse), Error>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return orphanedResults.removeValue(forKey: transferID)
    }

    // MARK: - Completion plumbing

    /// Removes and returns everything registered for `taskIdentifier`, under one lock
    /// acquisition. Returning the continuations here — rather than resuming inside the lock —
    /// is what makes "resumed exactly once" structurally true instead of merely intended.
    private func popState(for taskIdentifier: Int) -> (
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
        let state = popState(for: task.taskIdentifier)

        if let bodyFile = state.bodyFile {
            try? FileManager.default.removeItem(at: bodyFile)
        }

        if let error {
            logger.error("task \(task.taskIdentifier) failed: \(error, privacy: .public)")
            let wrapped = TransferError.transportError(underlying: error)
            state.upload?.resume(throwing: wrapped)
            state.download?.resume(throwing: wrapped)
            if state.upload == nil && state.download == nil, let id = task.taskDescription {
                recordOrphan(id: id, result: .failure(wrapped))
            }
            return
        }

        guard let http = task.response as? HTTPURLResponse else {
            state.upload?.resume(throwing: TransferError.invalidResponse)
            state.download?.resume(throwing: TransferError.invalidResponse)
            if state.upload == nil && state.download == nil, let id = task.taskDescription {
                recordOrphan(id: id, result: .failure(TransferError.invalidResponse))
            }
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
            return
        }

        // Nobody was waiting — this task completed while the app was suspended.
        if let id = task.taskDescription {
            recordOrphan(id: id, result: .success((state.data, http)))
        }
    }

    private func recordOrphan(id: String, result: Result<(Data, HTTPURLResponse), Error>) {
        stateLock.lock()
        orphanedResults[id] = result
        stateLock.unlock()
        logger.debug("recorded orphaned transfer result for \(id, privacy: .public)")
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
        stateLock.unlock()
        // UIKit requires this on the main queue.
        DispatchQueue.main.async { handler?() }
    }
}
