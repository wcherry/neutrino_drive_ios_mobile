import Foundation
import os.log
import NeutrinoCore

// MARK: - DeviceKeyRewrap

/// Moves one file's DEK from this device's stale key onto the account's published key.
///
/// Pure and static so the one step that can make a file unreadable — what gets sealed to whom —
/// is testable without a network or a Keychain.
enum DeviceKeyRewrap {

    /// The ref to file in place of `ref`, or nil when this device's key does not open it.
    ///
    /// Nil is the common answer and not a failure: a file uploaded from the web or any healthy
    /// device was sealed to the published key, which this device (holding a different one) cannot
    /// open. Those refs are already right and are left alone.
    ///
    /// Sealing needs only the published *public* key, which is why a device that does not hold the
    /// account's current secret can still repair the files only it can open.
    static func rewrap(_ ref: SealedFileKey,
                       devicePublicKey: String,
                       devicePrivateKey: String,
                       to published: PublishedKey) -> SealedFileKey? {
        guard let dek = SealedKeyCrypto.openDEK(sealedBase64URL: ref.sealed,
                                                publicKeyBase64URL: devicePublicKey,
                                                privateKeyBase64URL: devicePrivateKey),
              let sealed = SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: published.publicKey) else {
            return nil
        }
        return SealedFileKey(sealed: sealed, keyVersion: published.version)
    }
}

// MARK: - DeviceKeyRepairReport

struct DeviceKeyRepairReport: Codable, Equatable {
    /// Files whose key was moved onto the account's key. These now open everywhere.
    var rewrapped = 0
    /// Files this device's key does not open — sealed to the account's key already.
    var alreadyCorrect = 0
    /// Files with no key ref (not encrypted).
    var unencrypted = 0
    /// A read or write that failed after retries. Running the pass again picks these up.
    var failed = 0
    var finishedAt = Date()

    var examined: Int { rewrapped + alreadyCorrect + unencrypted + failed }

    var summary: String {
        var parts = ["\(rewrapped) repaired"]
        if failed > 0 { parts.append("\(failed) failed — run again to retry") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - DeviceKeyRepairState

enum DeviceKeyRepairState: Equatable {
    case unknown
    /// This device's key is the account's key. Nothing to do.
    case current
    /// It is not, and the repair pass has not run (or is about to).
    case stale
    case running(examined: Int, rewrapped: Int)
    /// The pass finished. The device is still stale — it needs the account's current key
    /// imported — but nothing it uploaded is unreadable elsewhere any more.
    case repaired(DeviceKeyRepairReport)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - DeviceKeyRepairService

/// Finds the files this device sealed to a key the account no longer publishes, and re-seals
/// each one to the key it does.
///
/// ## Why it has to run here
///
/// A file sealed to this device's old key can be opened by exactly one secret in the world: the
/// one in this device's Keychain. The server never sees a DEK, and no other client holds the old
/// key. So the repair can only happen on this device, and only *before* that key is replaced —
/// importing the account's current key overwrites it. That is why the pass starts on its own at
/// launch as soon as the key is found to be stale, rather than waiting for someone to find it.
///
/// ## Why it is safe
///
/// It only rewrites a ref that this device's key opens, and only the caller's own ref. The DEK and
/// the file's ciphertext are untouched — the same key, sealed to a different recipient — so a
/// rewrite that is interrupted, or run twice, leaves every file readable by at least the key it
/// was readable by before. A second run finds nothing left to do.
@MainActor
final class DeviceKeyRepairService: ObservableObject {

    @Published private(set) var state: DeviceKeyRepairState = .unknown

    weak var driveService: DriveService?
    private var inFlight = false

    static let pageSize = 200
    /// Key reads in flight at once. The pass reads one ref per file in the drive; strictly in
    /// series that is the better part of an hour on a large library.
    static let concurrency = 6
    static let backoff: [TimeInterval] = [1, 4, 16]

    private var logger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive", category: "DeviceKeyRepair")
    }

    /// Checks this device's key against the account's, and repairs straight away if it is stale.
    func checkAndRepair() async {
        // Launch and the first foreground both ask; the flag is set before the first await so the
        // second caller cannot start a second pass while the first is still reading the key.
        guard !inFlight, let driveService else { return }
        guard let stored = SealedKeyCrypto.storedKeyPair() else { return }
        inFlight = true
        defer { inFlight = false }

        let published: PublishedKey?
        do {
            published = try await driveService.publishedKey()
        } catch {
            // Offline, most likely. Say nothing: uploads check for themselves, and the next launch
            // or foreground asks again.
            logger.error("checkAndRepair: could not read the account's key: \(error, privacy: .public)")
            return
        }

        switch DeviceKeyCheck.status(storedPublicKey: stored.publicKey, published: published) {
        case .current:
            state = .current
        case .unpublished:
            // Nothing to seal to. Uploads refuse on their own; the provisioning flow publishes.
            state = .stale
        case .stale(let published):
            state = .stale
            await repair(to: published, deviceKey: stored)
        }
    }

    private func repair(to published: PublishedKey,
                        deviceKey: (publicKey: String, privateKey: String)) async {
        guard let driveService else { return }
        logger.info("repair: device key is stale; re-sealing its files to account key v\(published.version, privacy: .public)")

        var report = DeviceKeyRepairReport()
        state = .running(examined: 0, rewrapped: 0)
        var offset = 0

        while true {
            let ids: [String]
            do {
                ids = try await withBackoff { try await driveService.allFileIDsPage(limit: Self.pageSize, offset: offset) }
            } catch {
                logger.error("repair: listing failed at offset \(offset): \(error, privacy: .public)")
                state = .failed("Could not list your files: \(error.localizedDescription)")
                return
            }
            if ids.isEmpty { break }

            for chunk in stride(from: 0, to: ids.count, by: Self.concurrency) {
                let slice = ids[chunk..<min(chunk + Self.concurrency, ids.count)]
                let outcomes = await withTaskGroup(of: Outcome.self) { group in
                    for id in slice {
                        group.addTask { await self.repairOne(fileID: id, published: published, deviceKey: deviceKey) }
                    }
                    var all: [Outcome] = []
                    for await outcome in group { all.append(outcome) }
                    return all
                }
                for outcome in outcomes {
                    switch outcome {
                    case .rewrapped:      report.rewrapped += 1
                    case .alreadyCorrect: report.alreadyCorrect += 1
                    case .unencrypted:    report.unencrypted += 1
                    case .failed:         report.failed += 1
                    }
                }
                state = .running(examined: report.examined, rewrapped: report.rewrapped)
            }

            if ids.count < Self.pageSize { break }
            offset += Self.pageSize
        }

        report.finishedAt = Date()
        logger.info("repair: finished — \(report.rewrapped) re-sealed, \(report.alreadyCorrect) already right, \(report.failed) failed")
        state = .repaired(report)
    }

    private enum Outcome { case rewrapped, alreadyCorrect, unencrypted, failed }

    private func repairOne(fileID: String,
                           published: PublishedKey,
                           deviceKey: (publicKey: String, privateKey: String)) async -> Outcome {
        guard let driveService else { return .failed }
        let ref: SealedFileKey?
        do {
            ref = try await withBackoff { try await driveService.fileKey(fileID: fileID) }
        } catch {
            logger.error("repair: reading key for \(fileID, privacy: .public) failed: \(error, privacy: .public)")
            return .failed
        }
        guard let ref else { return .unencrypted }
        guard let rewrapped = DeviceKeyRewrap.rewrap(ref,
                                                     devicePublicKey: deviceKey.publicKey,
                                                     devicePrivateKey: deviceKey.privateKey,
                                                     to: published) else {
            return .alreadyCorrect
        }
        do {
            try await withBackoff { try await driveService.setFileKey(fileID: fileID, key: rewrapped) }
            return .rewrapped
        } catch {
            logger.error("repair: writing key for \(fileID, privacy: .public) failed: \(error, privacy: .public)")
            return .failed
        }
    }

    /// Retries the failures that describe a moment rather than a request: a transport error, 408,
    /// 429 and 5xx. Anything else fails the same way however often it is sent.
    private func withBackoff<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < Self.backoff.count, PhotoSyncService.isRetryable(error) else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(Self.backoff[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }
}
