import SwiftUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - DocumentWindowValue

/// Identifies a document window on iPad.
///
/// `WindowGroup(id:for:)` persists this value and hands it back when iOS restores a scene —
/// possibly after the app has been terminated — so it must be `Codable` and must carry enough
/// to rebuild the window **without** consulting in-memory state that will not exist yet. That
/// is why the name and MIME type are stored rather than just the file ID: a restored window can
/// show a title and pick the right viewer while the drive listing is still loading, instead of
/// flashing an empty shell.
///
/// It deliberately does *not* carry a decrypted URL or any file content. Scene-restoration
/// state is written to disk by the system, outside this app's encryption boundary; putting
/// plaintext or a key in it would leak exactly what the product exists to protect.
struct DocumentWindowValue: Codable, Hashable, Identifiable {
    let fileID: String
    let name: String
    let mimeType: String?

    var id: String { fileID }

    init(fileID: String, name: String, mimeType: String?) {
        self.fileID = fileID
        self.name = name
        self.mimeType = mimeType
    }

    init(item: DriveItem) {
        self.init(fileID: item.id, name: item.name, mimeType: item.mimeType)
    }

    /// Rebuilds a `DriveItem` good enough to drive a viewer. Fields the viewer does not use are
    /// filled with neutral defaults rather than guessed.
    var placeholderItem: DriveItem {
        DriveItem(id: fileID, name: name, type: .file, parentID: nil, size: nil,
                  modifiedAt: Date(), isTrashed: false, isShared: false, mimeType: mimeType)
    }
}

// MARK: - DocumentWindowView

/// The contents of a secondary document window.
///
/// Each window is an independent scene with its own view state, but shares the app's services
/// through the environment — two windows showing two files must not each hold their own
/// `DriveService` and its own copy of the drive tree.
struct DocumentWindowView: View {

    let value: DocumentWindowValue

    /// Owned per window, matching `FileBrowserView`. A download's progress belongs to the
    /// window showing it, so sharing one instance across windows would make two documents
    /// report each other's progress.
    @StateObject private var downloadService = DownloadService()

    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(value.name)
                .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if StreamingPlaybackService.isStreamableMedia(mimeType: value.mimeType) {
            MediaPlayerView(item: value.placeholderItem)
        } else if let errorMessage {
            ContentUnavailableCompat(title: "Couldn't open this file",
                                     message: errorMessage,
                                     systemImage: "exclamationmark.triangle")
        } else if isLoading {
            ProgressView("Opening \(value.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            QuickLookPreview(url: previewURL)
        }
    }

    private func load() async {
        guard previewURL == nil, errorMessage == nil else { return }
        guard !StreamingPlaybackService.isStreamableMedia(mimeType: value.mimeType) else {
            isLoading = false
            return
        }
        do {
            previewURL = try await downloadService.download(fileID: value.fileID,
                                                            fileName: value.name,
                                                            mimeType: value.mimeType)
            FileAccessTracker.shared.recordAccess(fileID: value.fileID, name: value.name,
                                                  mimeType: value.mimeType, sizeBytes: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - QuickLookPreview

/// Minimal QuickLook host. The `.quickLookPreview` modifier used elsewhere presents *over* a
/// view; a document window needs the preview to **be** the window's content.
private struct QuickLookPreview: View {
    let url: URL?

    var body: some View {
        if let url {
            QuickLookRepresentable(url: url).ignoresSafeArea(edges: .bottom)
        } else {
            ContentUnavailableCompat(title: "Nothing to preview",
                                     message: "This file could not be prepared.",
                                     systemImage: "doc")
        }
    }
}

private struct QuickLookRepresentable: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - DocumentWindowScene

/// Namespace for the secondary `WindowGroup`'s identifier, so the declaration site and every
/// `openWindow` call agree on one string rather than two literals that can drift apart.
enum DocumentWindowScene {
    static let identifier = "neutrino.document"
}
