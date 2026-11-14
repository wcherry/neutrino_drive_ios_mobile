import SwiftUI
import QuickLook

// MARK: - ZipArchiveDocument

/// A zip on disk to show in `ZipViewerView` — the payload for `.sheet(item:)`.
struct ZipArchiveDocument: Identifiable {
    let url: URL
    let name: String
    var id: URL { url }
}

// MARK: - ZipViewerModel

/// Owns the open archive and the files extracted out of it for QuickLook.
///
/// The reader seeks a single `FileHandle`, so every read goes through one serial queue rather than
/// racing on the main thread. Extracted entries land in a directory of their own that is removed
/// when the viewer closes, so a file opened from inside an archive does not outlive it on disk.
@MainActor
final class ZipViewerModel: ObservableObject {

    enum State {
        case loading
        case failed(String)
        case ready(ZipTree)
    }

    @Published private(set) var state: State = .loading
    @Published var previewURL: URL?
    @Published private(set) var extractingPath: String?
    @Published var errorMessage: String?

    private var reader: ZipArchiveReader?
    private let queue = DispatchQueue(label: "com.neutrino.drive.zipviewer")
    private let extractDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZipViewer-\(UUID().uuidString)", isDirectory: true)

    func open(_ url: URL) async {
        guard case .loading = state else { return }
        let result: Result<(ZipArchiveReader, ZipTree), Error> = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result {
                    let reader = try ZipArchiveReader(url: url)
                    return (reader, ZipTree(entries: reader.entries))
                })
            }
        }
        switch result {
        case .success(let (reader, tree)):
            self.reader = reader
            state = .ready(tree)
        case .failure(let error):
            state = .failed(error.localizedDescription)
        }
    }

    /// Inflates a file to disk under its own name and hands it to QuickLook, which previews it
    /// and offers Share / Save to Files.
    func preview(_ node: ZipTree.Node) {
        guard let reader, let entry = node.entry, extractingPath == nil else { return }
        extractingPath = node.path
        let directory = extractDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // The last segment only — the archive path is a display name, never a destination.
        let destination = directory.appendingPathComponent(node.name)

        queue.async { [weak self] in
            let result = Result<URL, Error> {
                let data = try reader.extract(entry)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: destination, options: .completeFileProtection)
                return destination
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.extractingPath = nil
                switch result {
                case .success(let url): self.previewURL = url
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // Removed with the model rather than on `onDisappear`, which can fire while QuickLook is
    // covering the viewer — deleting the very file on screen.
    deinit {
        try? FileManager.default.removeItem(at: extractDirectory)
    }
}

// MARK: - ZipViewerView

/// Browses a zip's folders and opens any file inside it.
struct ZipViewerView: View {

    let document: ZipArchiveDocument

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ZipViewerModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(document.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationDestination(for: String.self) { folder in
                    folderView(folder)
                }
        }
        .task { await model.open(document.url) }
        .quickLookPreview($model.previewURL)
        .alert("Couldn\u{2019}t Open File", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Reading archive\u{2026}")
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        case .ready:
            folderView("")
        }
    }

    @ViewBuilder
    private func folderView(_ folder: String) -> some View {
        if case .ready(let tree) = model.state {
            ZipFolderList(
                tree: tree,
                folder: folder,
                extractingPath: model.extractingPath,
                onOpenFile: { model.preview($0) }
            )
            .navigationTitle(folder.isEmpty ? document.name : (folder as NSString).lastPathComponent)
        }
    }
}

// MARK: - ZipFolderList

private struct ZipFolderList: View {

    let tree: ZipTree
    let folder: String
    let extractingPath: String?
    let onOpenFile: (ZipTree.Node) -> Void

    var body: some View {
        let rows = tree.list(folder)
        List {
            Section {
                if rows.isEmpty {
                    Text(folder.isEmpty ? "This archive is empty." : "This folder is empty.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { node in
                    if node.isDirectory {
                        NavigationLink(value: node.path) {
                            ZipNodeRow(node: node, isExtracting: false)
                        }
                    } else {
                        Button {
                            onOpenFile(node)
                        } label: {
                            ZipNodeRow(node: node, isExtracting: extractingPath == node.path)
                        }
                        .buttonStyle(.plain)
                        .disabled(extractingPath != nil)
                    }
                }
            } footer: {
                if folder.isEmpty {
                    Text("\(tree.fileCount) \(tree.fileCount == 1 ? "file" : "files") \u{00B7} \(ByteCountFormatter.string(fromByteCount: Int64(clamping: tree.totalSize), countStyle: .file))")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - ZipNodeRow

private struct ZipNodeRow: View {

    let node: ZipTree.Node
    let isExtracting: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isExtracting {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: node.size), countStyle: .file)
        guard let modified = node.modified else { return size }
        return "\(size) \u{00B7} \(modified.formatted(date: .abbreviated, time: .shortened))"
    }

    private var iconName: String {
        if node.isDirectory { return "folder.fill" }
        if node.isEncrypted { return "lock.doc" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "m4v", "webm": return "film"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return "music.note"
        case "zip", "tar", "gz", "tgz", "7z", "rar": return "archivebox"
        case "txt", "md", "json", "xml", "csv", "yaml", "yml", "log",
             "swift", "js", "ts", "py", "rs", "go", "java", "c", "h", "cpp", "html", "css", "sh":
            return "doc.text"
        default: return "doc"
        }
    }
}
