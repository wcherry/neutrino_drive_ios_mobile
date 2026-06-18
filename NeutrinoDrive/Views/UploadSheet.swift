import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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

/// Wraps PHPickerViewController for selecting a photo from the library.
private struct PhotoPickerRepresentable: UIViewControllerRepresentable {

    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                onCancel()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                guard let self else { return }
                guard error == nil, let image = object as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.9) else {
                    DispatchQueue.main.async { self.onCancel() }
                    return
                }
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("jpg")
                do {
                    try data.write(to: tempURL)
                    DispatchQueue.main.async { self.onPick(tempURL) }
                } catch {
                    DispatchQueue.main.async { self.onCancel() }
                }
            }
        }
    }
}

// MARK: - CameraPickerRepresentable

/// Wraps UIImagePickerController for capturing a photo with the camera.
private struct CameraPickerRepresentable: UIViewControllerRepresentable {

    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

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
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.9) else {
                onCancel()
                return
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("jpg")
            do {
                try data.write(to: tempURL)
                onPick(tempURL)
            } catch {
                onCancel()
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
/// progress, and reports the completed UploadResult back to the caller.
struct UploadSheet: View {

    // MARK: - Parameters

    @Binding var isPresented: Bool
    let parentFolderID: String?
    let onUploadComplete: (UploadResult) -> Void

    // MARK: - State

    @StateObject private var uploadService = UploadService()

    @State private var showDocumentPicker = false
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var uploadError: String?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if uploadService.isUploading {
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
                    .disabled(uploadService.isUploading)
                }
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerRepresentable(onPick: handlePick, onCancel: {})
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerRepresentable(onPick: handlePick, onCancel: {})
        }
        .sheet(isPresented: $showCameraPicker) {
            CameraPickerRepresentable(onPick: handlePick, onCancel: {})
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
            Text("Encrypting and uploading\u{2026}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
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
}

// MARK: - Preview

#Preview {
    UploadSheet(isPresented: .constant(true), parentFolderID: nil) { result in
        print("Uploaded: \(result.name) (\(result.id))")
    }
}
