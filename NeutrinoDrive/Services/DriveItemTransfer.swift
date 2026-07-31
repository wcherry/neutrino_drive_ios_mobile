import Foundation
import UniformTypeIdentifiers
import os.log

// MARK: - DriveItemTransfer

/// Drag and drop between Neutrino Drive and the rest of iOS — `mvp.md` Phase 6.
///
/// Two directions, and they are not symmetrical:
///
/// - **Out** (Drive → Files/Mail/Notes): the receiving app gets **decrypted** bytes. That is the
///   entire point of the gesture and cannot be otherwise — Mail cannot attach ciphertext it has
///   no key for. It is, though, the one interaction that deliberately carries data across the
///   encryption boundary, which is why it lives behind `FeatureFlags.dragAndDrop` and why the
///   decrypt runs through the **authenticated** path (`DownloadService` → `E2EEDownloader` →
///   `SecretStreamCrypto.decrypt`), never the unauthenticated streaming reader.
/// - **In** (Files/Mail/Notes → Drive): the incoming file is encrypted locally before it is
///   uploaded, using the same `E2EEUploader` every other upload path uses.
///
/// ## Why the decrypt is lazy
///
/// `NSItemProvider.registerFileRepresentation` hands back a closure that is invoked **only if a
/// drop actually happens**. Dragging a 2 GB video across the screen and releasing it over
/// nothing must not have downloaded and decrypted 2 GB. Registering the file eagerly would also
/// mean writing plaintext to disk for a gesture the user then abandoned.
enum DriveItemTransfer {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                       category: "DriveItemTransfer")

    // MARK: - Type Identifiers

    /// The UTI to advertise a dragged file as.
    ///
    /// Resolved from the MIME type where possible so a receiving app can decide whether it wants
    /// the drop — Mail treats `public.jpeg` differently from `public.data`. Dynamic types are
    /// rejected for the same reason as in `EncryptedMediaResourceLoader`: `UTType(mimeType:)`
    /// synthesises a `dyn.` placeholder for anything unrecognised, which conforms to nothing and
    /// tells the receiver less than `public.data` does.
    static func typeIdentifier(forMIMEType mimeType: String?, fileName: String) -> String {
        // The filename extension is consulted whenever the MIME type is absent, dynamic, **or
        // merely `public.data`**. That last case is the one worth spelling out: this backend
        // frequently stores `application/octet-stream`, which maps to a perfectly valid,
        // non-dynamic `public.data` — so a naive "use the MIME type if it resolves" check
        // succeeds and throws away the extension that would actually have told Mail or Notes
        // whether they can accept the drop.
        if let mimeType,
           let type = UTType(mimeType: mimeType),
           !type.isDynamic,
           type != .data {
            return type.identifier
        }
        let ext = (fileName as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic {
            return type.identifier
        }
        return UTType.data.identifier
    }

    /// Whether an item can be dragged out at all. Folders cannot: there is no single file to
    /// hand over, and a recursive export would be a different feature with different costs.
    static func canDrag(item: DriveItem) -> Bool {
        guard FeatureFlags.dragAndDrop else { return false }
        return item.type == .file
    }

    // MARK: - Drag Out

    /// An `NSItemProvider` that decrypts `item` **on drop**, not on drag.
    ///
    /// - Parameter loadFile: performs the download and decrypt. Injected so tests can drive the
    ///   provider without a server; production passes a `DownloadService` call.
    static func makeItemProvider(
        for item: DriveItem,
        loadFile: @escaping (DriveItem) async throws -> URL
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name

        let identifier = typeIdentifier(forMIMEType: item.mimeType, fileName: item.name)

        provider.registerFileRepresentation(
            forTypeIdentifier: identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let task = Task {
                do {
                    let url = try await loadFile(item)
                    // `false` for `coordinated`/ownership: the temp file belongs to us and the
                    // system copies it, so it must not be moved out from under the app.
                    completion(url, false, nil)
                } catch {
                    logger.error("drag export failed for \(item.id, privacy: .public): \(error, privacy: .public)")
                    completion(nil, false, error)
                }
            }
            let progress = Progress(totalUnitCount: 1)
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }

    // MARK: - Drop In

    /// A file that was dropped onto the app and is ready to upload.
    struct DroppedFile {
        let url: URL
        let fileName: String
        let mimeType: String
    }

    /// Extracts a droppable file from an `NSItemProvider`.
    ///
    /// Copies the delivered file into our own temp directory before returning. The URL handed to
    /// a `loadFileRepresentation` completion is valid **only for the duration of that closure**;
    /// returning it directly produces a URL that is already invalid by the time an upload starts
    /// — a bug that looks like an intermittent "file not found" and is miserable to diagnose.
    static func loadDroppedFile(from provider: NSItemProvider) async throws -> DroppedFile? {
        guard FeatureFlags.dragAndDrop else { return nil }
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .data) == true || UTType($0)?.conforms(to: .package) == true
        }) ?? provider.registeredTypeIdentifiers.first else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let name = provider.suggestedName ?? url.lastPathComponent
                do {
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("nd-drop-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: destination,
                                                            withIntermediateDirectories: true)
                    let copy = destination.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: DroppedFile(
                        url: copy,
                        fileName: name,
                        mimeType: mimeType(forTypeIdentifier: identifier, fileName: name)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The MIME type to record for an incoming file.
    ///
    /// Note this value is stored *inside* the encrypted metadata as well as on the file part, so
    /// getting it wrong means a file that downloads correctly and then opens in the wrong viewer.
    static func mimeType(forTypeIdentifier identifier: String, fileName: String) -> String {
        if let type = UTType(identifier), let mime = type.preferredMIMEType {
            return mime
        }
        let ext = (fileName as NSString).pathExtension
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
