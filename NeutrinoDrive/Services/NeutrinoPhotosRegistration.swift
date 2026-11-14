import Foundation
import AVFoundation
import Photos
import UniformTypeIdentifiers
import os.log

// Registering photo-sync uploads with the Neutrino Photos library (#45), so a library backed up
// by Drive shows up in Neutrino Photos on the web and on iOS.
//
// Opt-in ("Show in Neutrino Photos", off by default): someone also running Neutrino Photos' own
// backup would otherwise get every photo twice. Ledger-driven: an upload that completes with the
// setting on is marked waiting, by whichever process uploaded it, and the app registers what is
// waiting at the end of each drain — so the Photos extension's uploads are registered too.
//
// Live Photos follow the platform convention (neutrino#315): the clip is registered with its own
// `motionPhoto`, and the still carries `motionPhoto` plus `device.liveVideoFileID` naming the clip,
// in one complete write. Clients hide a clip that a still claims, so it shows once.

// MARK: - LibraryPhoto

/// A Neutrino Photos record: its id and its metadata document, kept as free-form JSON so a merge
/// keeps every key, including ones this build doesn't know.
struct LibraryPhoto {
    let id: String
    let metadata: [String: Any]?

    init(id: String, metadata: [String: Any]?) {
        self.id = id
        self.metadata = metadata
    }

    init(json data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else {
            throw DriveError.decodingError(underlying: NSError(
                domain: "LibraryPhoto", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "A photo record without an id."]))
        }
        self.init(id: id, metadata: object["metadata"] as? [String: Any])
    }
}

// MARK: - PhotoLibraryMetadata

/// The metadata document Drive writes for a photo. The `device` shape is Neutrino Photos'
/// `MediaDeviceFacts`, key for key, so both apps describe an item the same way.
enum PhotoLibraryMetadata {

    /// What classified a Drive-uploaded Live Photo: PhotoKit said so. Used as `motionPhoto.signal`
    /// whether or not the clip's content identifier could be read.
    static let photoKitSignal = "PHAssetMediaSubtype.photoLive"

    static func device(localIdentifier: String, isLivePhoto: Bool, isRAW: Bool,
                       subtypes: [String], liveVideoFileID: String?) -> [String: Any] {
        var device: [String: Any] = [
            "localIdentifier": localIdentifier,
            "isLivePhoto": isLivePhoto,
            "isRAW": isRAW,
            "subtypes": subtypes,
        ]
        if let liveVideoFileID { device["liveVideoFileID"] = liveVideoFileID }
        return device
    }

    static func motionPhoto(contentIdentifier: String?) -> [String: Any] {
        var motion: [String: Any] = ["subtype": "live_photo_apple", "signal": photoKitSignal]
        if let contentIdentifier { motion["contentIdentifier"] = contentIdentifier }
        return motion
    }

    /// `existing` with `adding` laid over it. One level deep for objects (`device`), so adding
    /// `liveVideoFileID` keeps the `device` facts already there; every other key is kept as is.
    static func merged(_ existing: [String: Any]?, adding: [String: Any]) -> [String: Any] {
        var result = existing ?? [:]
        for (key, value) in adding {
            if let new = value as? [String: Any], let old = result[key] as? [String: Any] {
                result[key] = old.merging(new) { _, newer in newer }
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Whether `metadata` already says everything `wanted` does — top-level keys, and the keys
    /// inside `device`. Registration answers with an existing record unchanged, so this is how
    /// the registrar tells whether it still has to merge.
    static func contains(_ wanted: [String: Any], in metadata: [String: Any]?) -> Bool {
        guard let metadata else { return wanted.isEmpty }
        for (key, value) in wanted {
            guard let present = metadata[key] else { return false }
            if let wantedObject = value as? [String: Any] {
                guard let presentObject = present as? [String: Any],
                      Set(wantedObject.keys).isSubset(of: Set(presentObject.keys)) else { return false }
            }
        }
        return true
    }

    /// `PHAssetMediaSubtype` as Neutrino Photos names them (`DevicePhotoLibrary.subtypeNames`).
    static func subtypeNames(_ subtypes: PHAssetMediaSubtype) -> [String] {
        var names: [String] = []
        if subtypes.contains(.photoPanorama)      { names.append("panorama") }
        if subtypes.contains(.photoHDR)           { names.append("hdr") }
        if subtypes.contains(.photoScreenshot)    { names.append("screenshot") }
        if subtypes.contains(.photoLive)          { names.append("live") }
        if subtypes.contains(.photoDepthEffect)   { names.append("portrait") }
        if subtypes.contains(.videoHighFrameRate) { names.append("slowMotion") }
        if subtypes.contains(.videoTimelapse)     { names.append("timelapse") }
        return names
    }

    /// The server's capture-date shape: UTC, no zone, no fraction. Anything else is dropped there.
    static func captureDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Dependencies

/// The three Photos API calls registration makes. `DriveService` in production.
@MainActor
protocol PhotoLibraryRegistering: AnyObject {
    func registerPhoto(fileID: String, captureDate: Date?, metadata: [String: Any]) async throws -> LibraryPhoto
    func libraryPhoto(id: String) async throws -> LibraryPhoto
    func replacePhotoMetadata(id: String, metadata: [String: Any]) async throws
}

extension DriveService: PhotoLibraryRegistering {}

/// What the device knows about an asset that the file doesn't say.
struct PhotoAssetFacts: Equatable {
    let creationDate: Date?
    let isLivePhoto: Bool
    let isRAW: Bool
    let subtypes: [String]
}

protocol PhotoAssetFactsProviding {
    /// Facts for each asset still in the library; a missing key means the asset is gone.
    func facts(forAssetIdentifiers identifiers: [String]) -> [String: PhotoAssetFacts]
    /// A Live Photo clip's `com.apple.quicktime.content.identifier`, read from the clip on this
    /// device; `nil` if it can't be read without downloading it.
    func contentIdentifier(forAssetIdentifier identifier: String) async -> String?
}

struct PHKitPhotoAssetFactsProvider: PhotoAssetFactsProviding {

    func facts(forAssetIdentifiers identifiers: [String]) -> [String: PhotoAssetFacts] {
        var found: [String: PhotoAssetFacts] = [:]
        for chunk in stride(from: 0, to: identifiers.count, by: 500) {
            let slice = Array(identifiers[chunk..<min(chunk + 500, identifiers.count)])
            PHAsset.fetchAssets(withLocalIdentifiers: slice, options: nil).enumerateObjects { asset, _, _ in
                let isRAW = PHAssetResource.assetResources(for: asset).contains {
                    UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
                }
                found[asset.localIdentifier] = PhotoAssetFacts(
                    creationDate: asset.creationDate,
                    isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                    isRAW: isRAW,
                    subtypes: PhotoLibraryMetadata.subtypeNames(asset.mediaSubtypes)
                )
            }
        }
        return found
    }

    func contentIdentifier(forAssetIdentifier identifier: String) async -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let clip = PHKitAssetExporter.pairedVideoResource(for: asset) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false   // a few MB, and only worth it if already here
        let written: Bool = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: clip, toFile: url, options: options) { error in
                continuation.resume(returning: error == nil)
            }
        }
        guard written else { return nil }
        let items = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        for item in items where item.identifier == .quickTimeMetadataContentIdentifier
            || (item.key as? String) == "com.apple.quicktime.content.identifier" {
            if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - Planner

/// Decides what to register for each asset waiting in the ledger. Pure, so the ordering rules —
/// the part that can quietly be wrong — are tested without PhotoKit or a network.
enum PhotoRegistrationPlanner {

    struct Job: Equatable {
        let assetIdentifier: String
        /// The still's ledger entry, its Drive file, and its record if it already has one.
        var stillFileID: String?
        var stillPhotoID: String?
        var registerStill = false
        /// The clip's Drive file, when its motion was uploaded; and whether to register it.
        var clipFileID: String?
        var clipPhotoID: String?
        var registerClip = false
    }

    struct Plan: Equatable {
        var jobs: [Job] = []
        /// Stills held back because their clip is still uploading — registered once it lands.
        var waitingForMotion = 0
        /// Entries that can't be registered: no Drive file id recorded (uploaded before the ledger
        /// kept one), or a clip whose still isn't in Neutrino Photos and isn't going to be.
        var unregistrable: [String] = []
    }

    static func plan(queue: PhotoSyncQueue) -> Plan {
        var assets: Set<String> = []
        for (id, record) in queue.completed where record.isAwaitingPhotoRegistration {
            assets.insert(PhotoSyncRules.parseEntryID(id).assetIdentifier)
        }

        var plan = Plan()
        for asset in assets.sorted() {
            let motionID = PhotoSyncRules.motionEntryID(forAssetIdentifier: asset)
            let still = queue.completed[asset]
            let clip = queue.completed[motionID]
            let stillWaiting = still?.isAwaitingPhotoRegistration == true
            let clipWaiting = clip?.isAwaitingPhotoRegistration == true

            if stillWaiting, still?.fileID == nil {
                plan.unregistrable.append(asset)
                if clipWaiting { plan.unregistrable.append(motionID) }
                continue
            }
            // The clip is still on its way: register the pair together once it lands, so the still
            // is written once, whole, with its `liveVideoFileID`.
            if stillWaiting, queue.pending.contains(where: { $0.id == motionID }) {
                plan.waitingForMotion += 1
                continue
            }
            // A clip alone would show up as a stray video. Only register it with its still.
            let stillInLibrary = still?.photoID != nil || stillWaiting
            if clipWaiting, !stillInLibrary || clip?.fileID == nil {
                plan.unregistrable.append(motionID)
                if !stillWaiting { continue }
            }

            var job = Job(assetIdentifier: asset)
            job.stillFileID = still?.fileID
            job.stillPhotoID = still?.photoID
            job.registerStill = stillWaiting
            job.clipFileID = clip?.fileID
            job.clipPhotoID = clip?.photoID
            job.registerClip = clipWaiting && stillInLibrary && clip?.fileID != nil
            plan.jobs.append(job)
        }
        return plan
    }
}

// MARK: - Report and state

struct PhotosRegistrationReport: Codable, Equatable {
    var registered = 0
    /// Waiting for their Live Photo motion to finish uploading; registered after it.
    var waitingForMotion = 0
    /// Uploaded before the ledger recorded a Drive file id, so there's nothing to register.
    var notLinked = 0
    var failed = 0
    var finishedAt = Date()

    var summary: String {
        var parts = ["\(registered) added"]
        if waitingForMotion > 0 { parts.append("\(waitingForMotion) waiting for Live Photo motion") }
        if notLinked > 0        { parts.append("\(notLinked) from before Drive kept a link") }
        if failed > 0           { parts.append("\(failed) failed, will retry") }
        return parts.joined(separator: ", ")
    }
}

enum PhotosRegistrationState: Equatable {
    case idle
    case running
    case finished(PhotosRegistrationReport)
    case failed(String)

    var isRunning: Bool { self == .running }
}

// MARK: - PhotoSyncService + registration

extension PhotoSyncService {

    /// Registers everything waiting in the ledger. Run at the end of each drain; never fatal —
    /// a failure leaves the entry waiting for the next one.
    @discardableResult
    func registerWaitingPhotos() async -> PhotosRegistrationReport {
        var report = PhotosRegistrationReport()
        guard let photoRegistrar else { return report }
        reloadQueue()
        let plan = PhotoRegistrationPlanner.plan(queue: queueSnapshot)
        report.waitingForMotion = plan.waitingForMotion
        for id in plan.unregistrable {
            mutateQueue { $0.stopAwaitingRegistration(id: id) }
            if !PhotoSyncRules.parseEntryID(id).isMotion { report.notLinked += 1 }
        }
        guard !plan.jobs.isEmpty else { return report }

        let facts = assetFactsProvider.facts(forAssetIdentifiers: plan.jobs.map(\.assetIdentifier))
        for job in plan.jobs {
            do {
                report.registered += try await register(job, facts: facts[job.assetIdentifier],
                                                        using: photoRegistrar)
            } catch DriveError.serverError(let code) where code == 404 {
                // The file is gone from Drive (deleted or trashed): nothing to register, ever.
                mutateQueue { queue in
                    queue.stopAwaitingRegistration(id: job.assetIdentifier)
                    queue.stopAwaitingRegistration(id: PhotoSyncRules.motionEntryID(forAssetIdentifier: job.assetIdentifier))
                }
            } catch {
                report.failed += 1
                registrationLogger.warning("registering \(job.assetIdentifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return report
    }

    /// Clip first, then the still in one complete write; or, for a clip added after its still was
    /// registered, the clip and then a merge into the still's record. Returns how many records it
    /// registered.
    private func register(_ job: PhotoRegistrationPlanner.Job, facts: PhotoAssetFacts?,
                          using registrar: PhotoLibraryRegistering) async throws -> Int {
        let asset = job.assetIdentifier
        let motionID = PhotoSyncRules.motionEntryID(forAssetIdentifier: asset)
        let hasMotion = job.clipFileID != nil
        let contentIdentifier = hasMotion ? await assetFactsProvider.contentIdentifier(forAssetIdentifier: asset) : nil
        let device = { (liveVideoFileID: String?) in
            PhotoLibraryMetadata.device(localIdentifier: asset, isLivePhoto: facts?.isLivePhoto ?? hasMotion,
                                        isRAW: facts?.isRAW ?? false, subtypes: facts?.subtypes ?? [],
                                        liveVideoFileID: liveVideoFileID)
        }
        var registered = 0

        if job.registerClip, let clipFileID = job.clipFileID {
            let metadata: [String: Any] = [
                "device": device(nil),
                "motionPhoto": PhotoLibraryMetadata.motionPhoto(contentIdentifier: contentIdentifier),
            ]
            let photo = try await registerEnsuringMetadata(clipFileID, metadata, facts, registrar)
            mutateQueue { $0.markRegistered(id: motionID, photoID: photo.id) }
            registered += 1
        }

        var stillMetadata: [String: Any] = ["device": device(job.clipFileID)]
        if hasMotion {
            stillMetadata["motionPhoto"] = PhotoLibraryMetadata.motionPhoto(contentIdentifier: contentIdentifier)
        }
        if job.registerStill, let stillFileID = job.stillFileID {
            let photo = try await registerEnsuringMetadata(stillFileID, stillMetadata, facts, registrar)
            mutateQueue { $0.markRegistered(id: asset, photoID: photo.id) }
            registered += 1
        } else if job.registerClip, let stillPhotoID = job.stillPhotoID {
            // The still was registered before its motion was uploaded: link it now. Read, merge,
            // write — the PUT replaces the whole document.
            let still = try await registrar.libraryPhoto(id: stillPhotoID)
            if !PhotoLibraryMetadata.contains(stillMetadata, in: still.metadata) {
                try await registrar.replacePhotoMetadata(
                    id: stillPhotoID, metadata: PhotoLibraryMetadata.merged(still.metadata, adding: stillMetadata))
            }
        }
        return registered
    }

    /// Registers a file and makes sure its record carries `metadata`. Registering a file that's
    /// already in the library (the web registers lazily) returns the existing record unchanged.
    private func registerEnsuringMetadata(_ fileID: String, _ metadata: [String: Any],
                                          _ facts: PhotoAssetFacts?,
                                          _ registrar: PhotoLibraryRegistering) async throws -> LibraryPhoto {
        let photo = try await registrar.registerPhoto(fileID: fileID, captureDate: facts?.creationDate,
                                                      metadata: metadata)
        if !PhotoLibraryMetadata.contains(metadata, in: photo.metadata) {
            try await registrar.replacePhotoMetadata(
                id: photo.id, metadata: PhotoLibraryMetadata.merged(photo.metadata, adding: metadata))
        }
        return photo
    }

    /// "Add Earlier Photos": marks every upload not yet in Neutrino Photos and registers it.
    func addEarlierPhotosToNeutrinoPhotos() async {
        guard !photosRegistrationState.isRunning else { return }
        guard showInNeutrinoPhotos else {
            photosRegistrationState = .failed("Turn on Show in Neutrino Photos first.")
            return
        }
        guard photoRegistrar != nil else {
            photosRegistrationState = .failed("Photo sync is not ready yet. Try again in a moment.")
            return
        }
        await tokenRefresher?()
        guard hasAccessTokenProvider() else {
            photosRegistrationState = .failed("Sign in to add photos to Neutrino Photos.")
            return
        }
        photosRegistrationState = .running
        mutateQueue { $0.markAllAwaitingRegistration() }
        var report = await registerWaitingPhotos()
        report.finishedAt = Date()
        lastPhotosRegistration = report
        photosRegistrationState = .finished(report)
    }

    private var registrationLogger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive", category: "NeutrinoPhotosRegistration")
    }
}
