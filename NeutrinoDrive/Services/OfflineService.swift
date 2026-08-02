import Foundation
import os.log

// MARK: - OfflineError

enum OfflineError: LocalizedError {
    case downloadFailed(underlying: Error)
    case fileWriteError(underlying: Error)
    case manifestError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let err):  return "Failed to download file for offline use: \(err.localizedDescription)"
        case .fileWriteError(let err):  return "Failed to save file for offline use: \(err.localizedDescription)"
        case .manifestError(let err):   return "Failed to update the offline file list: \(err.localizedDescription)"
        }
    }
}

// MARK: - OfflineService

@MainActor
final class OfflineService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var offlineFiles: [OfflineFile] = []

    // MARK: - Logging

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "OfflineService")

    // MARK: - Storage

    private let storageDirectory: URL

    private var manifestURL: URL {
        storageDirectory.appendingPathComponent("manifest.json")
    }

    // MARK: - Decoder / Encoder

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Init

    /// Production initializer. When `storageDirectory` is nil (the default), files are
    /// persisted under `Application Support/OfflineFiles` — durable across launches and not
    /// subject to `temporaryDirectory` purging. Tests inject an explicit temp directory so
    /// they never touch the real Application Support container.
    init(storageDirectory: URL? = nil) {
        let dir = storageDirectory ?? Self.defaultStorageDirectory()
        self.storageDirectory = dir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("init: failed to create storage directory: \(error, privacy: .public)")
        }
        self.offlineFiles = Self.loadManifest(from: dir, decoder: Self.decoder)
    }

    #if DEBUG
    /// Seed state for unit tests — bypasses manifest loading entirely.
    convenience init(offlineFiles: [OfflineFile], storageDirectory: URL? = nil) {
        self.init(storageDirectory: storageDirectory)
        self.offlineFiles = offlineFiles
    }
    #endif

    private static func defaultStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("OfflineFiles", isDirectory: true)
    }

    private static func loadManifest(from directory: URL, decoder: JSONDecoder) -> [OfflineFile] {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([OfflineFile].self, from: data)) ?? []
    }

    // MARK: - Queries

    func isOffline(fileID: String) -> Bool {
        offlineFiles.contains { $0.id == fileID }
    }

    func cacheSizeBytes() -> Int64 {
        offlineFiles.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Bytes held by files smart offline sync placed here, which is what its budget governs.
    /// User-pinned files sit outside the budget — see `SmartOfflineSyncService`.
    func managedCacheSizeBytes() -> Int64 {
        offlineFiles.filter(\.isManaged).reduce(0) { $0 + $1.sizeBytes }
    }

    func pinnedCacheSizeBytes() -> Int64 {
        offlineFiles.filter { !$0.isManaged }.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Recomputes the managed total from **actual file sizes on disk** rather than from the
    /// manifest's recorded sizes.
    ///
    /// The two can drift: a download that fails partway, a manifest written before a file was
    /// truncated, or an entry whose file was removed by the system under storage pressure all
    /// leave the manifest overstating or understating reality. A budget enforced against a
    /// running total rather than the filesystem is a budget that eventually stops meaning
    /// anything, so this is what Settings displays.
    func actualManagedCacheSizeBytes() -> Int64 {
        offlineFiles.filter(\.isManaged).reduce(0) { total, entry in
            total + (resolvedSizeBytes(at: entry.localURL) ?? 0)
        }
    }

    // MARK: - Mutations

    /// Downloads and decrypts `item` via `downloadService`, copies the plaintext into durable
    /// storage, and records it in the manifest. Reuses `DownloadService.download` rather than
    /// reimplementing the decrypt flow.
    /// - Parameter isManaged: true when smart offline sync placed this file, false when the
    ///   user explicitly pinned it. Only managed entries are ever evicted. Defaults to false so
    ///   every existing call site keeps producing a pinned file, which is the safe reading.
    func makeAvailableOffline(item: DriveItem,
                              downloadService: DownloadService,
                              isManaged: Bool = false) async throws {
        logger.debug("makeAvailableOffline: id=\(item.id, privacy: .public) name=\(item.name, privacy: .public)")

        let tempURL: URL
        do {
            tempURL = try await downloadService.download(
                fileID: item.id, fileName: item.name, mimeType: item.mimeType
            )
        } catch {
            logger.error("makeAvailableOffline: download failed: \(error, privacy: .public)")
            throw OfflineError.downloadFailed(underlying: error)
        }

        let destDir = storageDirectory.appendingPathComponent(item.id, isDirectory: true)
        let destURL = destDir.appendingPathComponent(item.name)
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: tempURL, to: destURL)
        } catch {
            logger.error("makeAvailableOffline: file copy failed: \(error, privacy: .public)")
            throw OfflineError.fileWriteError(underlying: error)
        }

        let sizeBytes = resolvedSizeBytes(at: destURL) ?? item.size ?? 0
        let entry = OfflineFile(
            id: item.id,
            name: item.name,
            mimeType: item.mimeType ?? "application/octet-stream",
            sizeBytes: sizeBytes,
            localURL: destURL,
            cachedAt: Date(),
            isManaged: isManaged
        )

        // A file the user pinned must stay pinned even if smart sync happens to re-download
        // it: downgrading it to managed would quietly make it evictable.
        let wasPinned = offlineFiles.contains { $0.id == item.id && !$0.isManaged }
        offlineFiles.removeAll { $0.id == item.id }
        offlineFiles.append(wasPinned ? OfflineFile(id: entry.id, name: entry.name,
                                                    mimeType: entry.mimeType,
                                                    sizeBytes: entry.sizeBytes,
                                                    localURL: entry.localURL,
                                                    cachedAt: entry.cachedAt,
                                                    isManaged: false)
                                      : entry)
        try persistManifest()
        logger.debug("makeAvailableOffline succeeded: id=\(item.id, privacy: .public)")
    }

    /// Deletes both the local file and its manifest entry.
    func removeOffline(fileID: String) {
        guard let idx = offlineFiles.firstIndex(where: { $0.id == fileID }) else { return }
        let entry = offlineFiles[idx]
        logger.debug("removeOffline: id=\(fileID, privacy: .public)")
        try? FileManager.default.removeItem(at: entry.localURL)
        // Best-effort cleanup of the per-file directory created by makeAvailableOffline
        // (`<storageDirectory>/<fileID>/<fileName>`). Only remove it if it's actually empty —
        // fixtures in tests place files directly under the storage/temp directory rather than
        // in a per-ID subdirectory, so a blind recursive delete here would destroy sibling
        // files/manifest that don't belong to this entry.
        let parentDir = entry.localURL.deletingLastPathComponent()
        if parentDir != storageDirectory,
           let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: parentDir)
        }
        offlineFiles.remove(at: idx)
        try? persistManifest()
    }

    /// Removes a file **only if** smart offline sync placed it there.
    ///
    /// The guard is the entire point: eviction runs automatically, and an automatic process
    /// that can delete a file the user explicitly asked to keep offline is a bug that only
    /// surfaces when they are somewhere with no signal. Refusing here rather than trusting the
    /// caller means the invariant holds even if a future planner gets its filtering wrong.
    func evictManaged(fileID: String) {
        guard let entry = offlineFiles.first(where: { $0.id == fileID }) else { return }
        guard entry.isManaged else {
            logger.debug("evictManaged: refusing to evict user-pinned \(fileID, privacy: .public)")
            return
        }
        removeOffline(fileID: fileID)
    }

    /// Removes every cached file. Used by Settings' "Clear Offline Cache" action.
    func removeAll() {
        for entry in offlineFiles {
            removeOffline(fileID: entry.id)
        }
    }

    // MARK: - Private Helpers

    private func resolvedSizeBytes(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        if let size = attrs[.size] as? Int64 { return size }
        if let size = attrs[.size] as? UInt64 { return Int64(size) }
        if let size = attrs[.size] as? NSNumber { return size.int64Value }
        return nil
    }

    private func persistManifest() throws {
        do {
            let data = try Self.encoder.encode(offlineFiles)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            logger.error("persistManifest failed: \(error, privacy: .public)")
            throw OfflineError.manifestError(underlying: error)
        }
    }
}
