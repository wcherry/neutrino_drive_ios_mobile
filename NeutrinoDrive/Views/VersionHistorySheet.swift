import SwiftUI
import NeutrinoAuth

// MARK: - VersionHistorySheet

/// Lists a file's previous versions, and allows viewing or restoring one.
///
/// Viewing a historical version routes through `DownloadService` with a `versionID`, so the
/// bytes take the same fetch-key → unseal → secretstream-decrypt path as a current file.
struct VersionHistorySheet: View {

    // MARK: - Parameters

    let item: DriveItem

    // MARK: - Environment

    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @StateObject private var versionService = VersionHistoryService()
    @StateObject private var downloadService = DownloadService()

    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var pendingRestore: FileVersion?
    @State private var busyVersionID: String?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if versionService.isLoading && versionService.versions.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if versionService.versions.isEmpty {
                    emptyState
                } else {
                    versionList
                }
            }
            .navigationTitle("Version History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                versionService.authService = authService
                await versionService.loadVersions(fileID: item.id)
            }
            .quickLookPreview($previewURL)
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "Restore this version?",
                isPresented: Binding(
                    get: { pendingRestore != nil },
                    set: { if !$0 { pendingRestore = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Restore") {
                    if let version = pendingRestore { restore(version) }
                    pendingRestore = nil
                }
                Button("Cancel", role: .cancel) { pendingRestore = nil }
            } message: {
                Text("\u{201C}\(item.name)\u{201D} will be replaced with this version. The current version is saved to history first, so this can be undone.")
            }
        }
    }

    // MARK: - List

    private var versionList: some View {
        List {
            Section {
                ForEach(versionService.versions) { version in
                    versionRow(version)
                }
            } footer: {
                Text("Older versions are encrypted with the same key as the current file and are decrypted on this device.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func versionRow(_ version: FileVersion) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(version.displayName)
                        .font(.body)
                    if version.isNamed {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: version.sizeBytes, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if busyVersionID == version.id {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { view(version) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                pendingRestore = version
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                view(version)
            } label: {
                Label("View This Version", systemImage: "eye")
            }
            Button {
                pendingRestore = version
            } label: {
                Label("Restore This Version", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No Previous Versions")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Versions appear here when this file is changed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: - Actions

    private func view(_ version: FileVersion) {
        guard busyVersionID == nil else { return }
        busyVersionID = version.id
        Task {
            defer { busyVersionID = nil }
            do {
                // Same decrypt path as a current file — only the blob URL differs.
                previewURL = try await downloadService.download(
                    fileID: item.id,
                    fileName: versionedFileName(for: version),
                    mimeType: item.mimeType,
                    versionID: version.id
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Disambiguates the preview's filename so a restored-then-viewed version does not sit in
    /// QuickLook under the same name as the current file.
    private func versionedFileName(for version: FileVersion) -> String {
        let base = (item.name as NSString).deletingPathExtension
        let ext  = (item.name as NSString).pathExtension
        let suffix = "v\(version.versionNumber)"
        return ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
    }

    private func restore(_ version: FileVersion) {
        busyVersionID = version.id
        Task {
            defer { busyVersionID = nil }
            do {
                try await versionService.restore(fileID: item.id, versionID: version.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VersionHistorySheet(item: DriveItem(id: "f1", name: "Report.pdf", type: .file, parentID: nil,
                                        size: 1024, modifiedAt: Date(), isTrashed: false,
                                        isShared: false, mimeType: "application/pdf"))
        .environmentObject(AuthService())
}
