import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os.log

// MARK: - DocumentPickerRepresentable

/// Wraps UIDocumentPickerViewController for use in SwiftUI.
private struct DocumentPickerRepresentable: UIViewControllerRepresentable {

    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data, .item],
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

// MARK: - PhotoPickerRepresentable

/// Wraps PHPickerViewController for picking photos and videos from the library.
///
/// Hands back the raw results, not images: turning one into the original file is
/// ``PickedMediaLoader``'s job, and doing it here as a `UIImage` is what used to re-encode every
/// pick as a JPEG with no metadata (#43).
private struct PhotoPickerRepresentable: UIViewControllerRepresentable {

    let onPick: ([PHPickerResult]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // `photoLibrary: .shared()` is what fills in `assetIdentifier`, the key to the library route.
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0
        config.filter = .any(of: [.images, .videos, .livePhotos])
        // `.automatic` may transcode a HEIC to JPEG on the way out. `.current` hands over the
        // asset as it is stored.
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: ([PHPickerResult]) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping ([PHPickerResult]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            results.isEmpty ? onCancel() : onPick(results)
        }
    }
}

// MARK: - CameraPickerRepresentable

/// Wraps UIImagePickerController for capturing a photo with the camera.
private struct CameraPickerRepresentable: UIViewControllerRepresentable {

    let onPick: (PickedMedia) -> Void
    let onFailure: (Error) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onFailure: onFailure, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            // Camera not available (e.g. simulator) — dismiss immediately.
            DispatchQueue.main.async { self.onCancel() }
            return UIImagePickerController()
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onPick: (PickedMedia) -> Void
        private let onFailure: (Error) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (PickedMedia) -> Void, onFailure: @escaping (Error) -> Void,
             onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onFailure = onFailure
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            do {
                let media = try CameraCaptureEncoder.encode(
                    image: image,
                    metadata: info[.mediaMetadata] as? [String: Any],
                    capturedAt: Date()
                )
                onPick(media)
            } catch {
                onFailure(error)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onCancel()
        }
    }
}

// MARK: - UploadSheet

/// Sheet that lets the user choose an upload source, tracks encrypt-and-upload
/// progress, and reports each completed UploadResult back to the caller.
struct UploadSheet: View {

    // MARK: - Parameters

    @Binding var isPresented: Bool
    let parentFolderID: String?
    /// Applies a picked photo's capture date when the server didn't keep the one sent with the
    /// upload. Wired to `DriveService.setImportMetadata`; `nil` skips the fallback.
    var stampImportMetadata: ((String, DriveImportMetadata) async throws -> Void)? = nil
    /// Called once per uploaded file. A multi-select from Photos calls it several times.
    let onUploadComplete: (UploadResult) -> Void

    // MARK: - State

    @StateObject private var uploadService = UploadService()

    @State private var showDocumentPicker = false
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var uploadError: String?
    /// True for the whole of a batch, including the export between one upload and the next,
    /// when `uploadService.isUploading` is briefly false.
    @State private var isWorking = false
    /// 1-based position in a multi-item batch; `nil` when there is one item.
    @State private var batchPosition: (index: Int, total: Int)?

    private let loader = PickedMediaLoader()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "UploadSheet")

    private var isBusy: Bool { isWorking || uploadService.isUploading }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if isBusy {
                    uploadingView
                } else {
                    sourcePickerForm
                }
            }
            .navigationTitle("Upload File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .disabled(isBusy)
                }
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerRepresentable(onPick: handlePick, onCancel: {})
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerRepresentable(onPick: handlePickedResults, onCancel: {})
        }
        .sheet(isPresented: $showCameraPicker) {
            CameraPickerRepresentable(
                onPick: { media in upload([.ready(media)]) },
                onFailure: { uploadError = $0.localizedDescription },
                onCancel: {}
            )
        }
        .alert("Upload Failed", isPresented: Binding(
            get: { uploadError != nil },
            set: { if !$0 { uploadError = nil } }
        )) {
            Button("OK") { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
    }

    // MARK: - Source Picker

    private var sourcePickerForm: some View {
        Form {
            Section("Upload From") {
                Button {
                    showDocumentPicker = true
                } label: {
                    Label("From Files", systemImage: "folder.badge.plus")
                }

                Button {
                    showPhotoPicker = true
                } label: {
                    Label("From Photos", systemImage: "photo.on.rectangle")
                }

                Button {
                    showCameraPicker = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
        }
    }

    // MARK: - Uploading View

    private var uploadingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: uploadService.progress)
                .progressViewStyle(.linear)
                .padding(.horizontal)
            Text(uploadingText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private var uploadingText: String {
        guard let batchPosition else { return "Encrypting and uploading\u{2026}" }
        return "Uploading \(batchPosition.index) of \(batchPosition.total)\u{2026}"
    }

    // MARK: - Upload Trigger

    private func handlePick(_ url: URL) {
        Task {
            do {
                let result = try await uploadService.upload(
                    fileURL: url,
                    parentFolderID: parentFolderID
                )
                onUploadComplete(result)
                isPresented = false
            } catch {
                uploadError = error.localizedDescription
            }
        }
    }

    private func handlePickedResults(_ results: [PHPickerResult]) {
        upload(results.map { .fromLibrary(PickerResultItem(result: $0)) })
    }

    /// One thing to upload: either ready (a camera capture) or still to be read from the library.
    private enum Pending {
        case ready(PickedMedia)
        case fromLibrary(PickedItem)
    }

    /// Uploads a batch one item at a time, keeping going past failures so one unreadable pick
    /// doesn't cost the rest. Successes are reported as they land; failures are summarised at
    /// the end, and the sheet stays open to show them.
    private func upload(_ items: [Pending]) {
        guard !items.isEmpty else { return }
        isWorking = true
        Task {
            var failures: [String] = []
            for (offset, item) in items.enumerated() {
                batchPosition = items.count > 1 ? (offset + 1, items.count) : nil
                do {
                    let files: [PickedMedia]
                    switch item {
                    case .ready(let ready): files = [ready]
                    case .fromLibrary(let picked): files = try await loader.load(picked)
                    }
                    // A Live Photo is two files, its photo and then its motion (#42). The item
                    // counts once: it fails if its photo does, and a clip that doesn't make it
                    // costs only the motion — the photo is already in Drive.
                    for (index, media) in files.enumerated() {
                        do {
                            let result = try await uploadService.upload(
                                data: media.data,
                                fileName: media.fileName,
                                mimeType: media.mimeType,
                                parentFolderID: parentFolderID,
                                thumbnailBase64: media.thumbnailBase64,
                                importMetadata: media.importMetadata
                            )
                            await PickedMediaUpload.stampIfNeeded(result: result, metadata: media.importMetadata,
                                                                  stamp: stampImportMetadata, logger: logger)
                            onUploadComplete(result)
                        } catch where index > 0 {
                            logger.warning("motion for picked item \(offset + 1) not uploaded: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                } catch {
                    logger.error("upload of picked item \(offset + 1) failed: \(error.localizedDescription, privacy: .public)")
                    failures.append(error.localizedDescription)
                }
            }
            batchPosition = nil
            isWorking = false
            if failures.isEmpty {
                isPresented = false
            } else {
                uploadError = Self.failureSummary(failures, of: items.count)
            }
        }
    }

    /// "This photo couldn't be read." for one item; "2 of 5 items couldn't be uploaded. …" for a batch.
    static func failureSummary(_ failures: [String], of total: Int) -> String {
        guard total > 1 else { return failures.first ?? "" }
        let reasons = Array(Set(failures)).sorted().joined(separator: "\n")
        return "\(failures.count) of \(total) items couldn't be uploaded.\n\(reasons)"
    }
}

// MARK: - Preview

#Preview {
    UploadSheet(isPresented: .constant(true), parentFolderID: nil) { result in
        print("Uploaded: \(result.name) (\(result.id))")
    }
}
