import SwiftUI
import QuickLook

// MARK: - OfflineView

/// Lists files the user has marked "Available Offline". Tapping a row opens it directly from
/// its local URL via QuickLook — no network call, since the plaintext is already on disk.
struct OfflineView: View {

    // MARK: - Environment

    @EnvironmentObject var offlineService: OfflineService

    // MARK: - State

    @State private var previewURL: URL?

    // MARK: - Body

    var body: some View {
        Group {
            if offlineService.offlineFiles.isEmpty {
                emptyStateView
            } else {
                fileList
            }
        }
        .navigationTitle("Offline")
        .quickLookPreview($previewURL)
    }

    // MARK: - File List

    private var fileList: some View {
        List {
            ForEach(offlineService.offlineFiles) { file in
                Button {
                    // A manifest entry whose local file no longer resolves (e.g. the app's
                    // storage was cleared out of band) is tolerated rather than crashing —
                    // simply do nothing if it's missing.
                    guard FileManager.default.fileExists(atPath: file.localURL.path) else { return }
                    previewURL = file.localURL
                } label: {
                    FileRowView(item: DriveItem(offlineFile: file))
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        offlineService.removeOffline(fileID: file.id)
                    } label: {
                        Label("Remove Offline", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        offlineService.removeOffline(fileID: file.id)
                    } label: {
                        Label("Remove Offline", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No Offline Files")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Files you mark available offline will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}

// MARK: - DriveItem convenience initialiser

private extension DriveItem {
    init(offlineFile: OfflineFile) {
        self.init(
            id: offlineFile.id,
            name: offlineFile.name,
            type: .file,
            parentID: nil,
            size: offlineFile.sizeBytes,
            modifiedAt: offlineFile.cachedAt,
            isTrashed: false,
            isShared: false,
            mimeType: offlineFile.mimeType
        )
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        OfflineView()
            .environmentObject(OfflineService())
    }
}
