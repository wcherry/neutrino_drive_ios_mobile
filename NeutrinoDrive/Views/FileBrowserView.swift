import SwiftUI
import QuickLook

// MARK: - FileBrowserView

/// Displays the contents of a Drive section, supporting folder navigation,
/// swipe actions, context menus, and sheet presentation for mutations.
struct FileBrowserView: View {

    // MARK: - Parameters

    let section: DriveSection
    let parentID: String?

    // MARK: - Environment

    @EnvironmentObject var driveService: DriveService
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var offlineService: OfflineService

    // MARK: - State

    @State private var showCreateFolder = false
    @State private var showUpload = false
    @State private var showEmptyTrashConfirmation = false
    @State private var itemToRename: DriveItem?
    @State private var itemToMove: DriveItem?
    @State private var itemToShare: DriveItem?
    @State private var itemForVersionHistory: DriveItem?

    @StateObject private var downloadService = DownloadService()
    @State private var previewURL: URL?
    @State private var downloadError: String?
    @State private var nativeViewerItem: DriveItem?

    @StateObject private var searchService = SearchService()
    @State private var searchText = ""

    // MARK: - Computed

    private var currentItems: [DriveItem] {
        driveService.items(in: section, parentID: parentID)
    }

    /// True while a My Drive search is active and should replace `currentItems` in the list.
    private var isSearchActive: Bool {
        FeatureFlags.search && section == .myDrive
            && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var navigationTitle: String {
        if let parentID {
            return driveService.allItems.first(where: { $0.id == parentID })?.name ?? section.rawValue
        }
        return section.rawValue
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isSearchActive {
                if searchService.isSearching && searchService.results.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchService.results.isEmpty {
                    searchEmptyStateView
                } else {
                    searchResultsList
                }
            } else if driveService.isLoading && currentItems.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if currentItems.isEmpty {
                emptyStateView
            } else {
                fileList
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .task(id: "\(section.rawValue)-\(parentID ?? "root")") {
            await driveService.loadSection(section, parentID: parentID)
        }
        .modifier(MyDriveSearchModifier(isEnabled: FeatureFlags.search && section == .myDrive, searchText: $searchText))
        .task(id: searchText) {
            guard FeatureFlags.search else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await searchService.search(query: searchText)
        }
        .task {
            searchService.authService = authService
        }
        .alert("Error", isPresented: Binding(
            get: { driveService.error != nil },
            set: { if !$0 { driveService.error = nil } }
        )) {
            Button("OK") { driveService.error = nil }
        } message: {
            Text(driveService.error ?? "")
        }
        .sheet(isPresented: $showCreateFolder) {
            CreateFolderSheet(isPresented: $showCreateFolder, parentID: parentID) { folderName in
                driveService.createFolder(name: folderName, parentID: parentID)
            }
        }
        .sheet(isPresented: $showUpload) {
            UploadSheet(isPresented: $showUpload, parentFolderID: parentID) { result in
                driveService.fileWasUploaded(result)
            }
        }
        .sheet(item: $itemToRename) { item in
            RenameSheet(item: item) { newName in
                driveService.rename(itemID: item.id, to: newName)
            }
        }
        .sheet(item: $itemToMove) { item in
            MoveSheet(item: item) { newParentID in
                driveService.move(itemID: item.id, to: newParentID)
            }
            .environmentObject(driveService)
        }
        .sheet(item: $itemToShare) { item in
            ShareSheet(item: item)
                .environmentObject(authService)
        }
        .sheet(item: $itemForVersionHistory) { item in
            VersionHistorySheet(item: item)
                .environmentObject(authService)
        }
        .quickLookPreview($previewURL)
        .sheet(item: $nativeViewerItem) { item in
            NeutrinoFileViewer(item: item)
        }
        .alert("Download Failed", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK") { downloadError = nil }
        } message: {
            Text(downloadError ?? "")
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $showEmptyTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                driveService.emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all items in the Trash. This action cannot be undone.")
        }
    }

    // MARK: - File List

    private var fileList: some View {
        List {
            ForEach(currentItems) { item in
                fileRow(for: item)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if downloadService.isDownloading {
                downloadingOverlay
            }
        }
    }

    // MARK: - Search Results List

    private var searchResultsList: some View {
        List {
            ForEach(searchService.results) { item in
                fileRow(for: item)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var searchEmptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No Results")
                .font(.title2)
                .fontWeight(.semibold)
            Text("No files match \u{201C}\(searchText)\u{201D}.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var downloadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: downloadService.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
                    .tint(.white)
                Text("Downloading\u{2026}")
                    .foregroundStyle(.white)
                    .font(.subheadline)
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func fileRow(for item: DriveItem) -> some View {
        Group {
            if item.type == .folder {
                NavigationLink(value: item) {
                    FileRowView(item: item)
                }
            } else if FeatureFlags.viewNeutrinoFiles && item.isNeutrinoNativeFormat {
                Button {
                    nativeViewerItem = item
                } label: {
                    FileRowView(item: item)
                }
                .buttonStyle(.plain)
            } else if FeatureFlags.downloadFiles {
                Button {
                    startDownload(for: item)
                } label: {
                    FileRowView(item: item)
                }
                .buttonStyle(.plain)
                .disabled(downloadService.isDownloading)
            } else {
                FileRowView(item: item)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            trailingSwipeActions(for: item)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            leadingSwipeActions(for: item)
        }
        .contextMenu {
            contextMenuItems(for: item)
        }
    }

    // MARK: - Swipe Actions

    @ViewBuilder
    private func trailingSwipeActions(for item: DriveItem) -> some View {
        switch section {
        case .myDrive:
            Button(role: .destructive) {
                driveService.delete(itemID: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        case .trash:
            Button(role: .destructive) {
                driveService.delete(itemID: item.id)
            } label: {
                Label("Delete Forever", systemImage: "trash.slash")
            }
        case .shared, .recents, .starred:
            EmptyView()
        }
    }

    @ViewBuilder
    private func leadingSwipeActions(for item: DriveItem) -> some View {
        switch section {
        case .myDrive:
            Button {
                itemToRename = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
        case .trash:
            Button {
                driveService.restore(itemID: item.id)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.green)
        case .starred:
            // Unstarring from the Starred list removes the row, which is the natural
            // swipe affordance here.
            if FeatureFlags.favorites {
                Button {
                    driveService.setStarred(itemID: item.id, isStarred: false)
                } label: {
                    Label("Unstar", systemImage: "star.slash")
                }
                .tint(.yellow)
            }
        case .shared, .recents:
            EmptyView()
        }
    }

    // MARK: - Context Menu

    /// Actions that apply to an item wherever it is listed — My Drive, Starred, Recents, or
    /// Shared. Factored out so the Starred section is not a second-class list missing the very
    /// action (unstar) users will reach for there most.
    @ViewBuilder
    private func sharedItemActions(for item: DriveItem) -> some View {
        if FeatureFlags.favorites {
            Button {
                driveService.setStarred(itemID: item.id, isStarred: !item.isStarred)
            } label: {
                if item.isStarred {
                    Label("Remove Star", systemImage: "star.slash")
                } else {
                    Label("Add Star", systemImage: "star")
                }
            }
        }
        if FeatureFlags.sharing {
            Button {
                itemToShare = item
            } label: {
                Label("Share\u{2026}", systemImage: "person.badge.plus")
            }
        }
        if FeatureFlags.versionHistory && item.type == .file {
            Button {
                itemForVersionHistory = item
            } label: {
                Label("Version History", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: DriveItem) -> some View {
        switch section {
        case .starred, .shared, .recents:
            if item.type == .file && FeatureFlags.viewNeutrinoFiles && item.isNeutrinoNativeFormat {
                Button {
                    nativeViewerItem = item
                } label: {
                    Label("Open", systemImage: "doc.text.magnifyingglass")
                }
                Divider()
            } else if item.type == .file && FeatureFlags.downloadFiles {
                Button {
                    startDownload(for: item)
                } label: {
                    Label("Download & Open", systemImage: "arrow.down.circle")
                }
                Divider()
            }
            sharedItemActions(for: item)
        case .myDrive:
            if item.type == .file && FeatureFlags.viewNeutrinoFiles && item.isNeutrinoNativeFormat {
                Button {
                    nativeViewerItem = item
                } label: {
                    Label("Open", systemImage: "doc.text.magnifyingglass")
                }
                Divider()
            } else if item.type == .file && FeatureFlags.downloadFiles {
                Button {
                    startDownload(for: item)
                } label: {
                    Label("Download & Open", systemImage: "arrow.down.circle")
                }
                Divider()
            }
            if item.type == .file && FeatureFlags.offlineFiles {
                Button {
                    toggleOffline(for: item)
                } label: {
                    if offlineService.isOffline(fileID: item.id) {
                        Label("Remove Offline", systemImage: "arrow.down.circle.fill")
                    } else {
                        Label("Make Available Offline", systemImage: "arrow.down.circle")
                    }
                }
                Divider()
            }
            Button {
                itemToRename = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                itemToMove = item
            } label: {
                Label("Move", systemImage: "folder")
            }
            Divider()
            sharedItemActions(for: item)
            Divider()
            Button(role: .destructive) {
                driveService.delete(itemID: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        case .trash:
            Button {
                driveService.restore(itemID: item.id)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                driveService.delete(itemID: item.id)
            } label: {
                Label("Delete Forever", systemImage: "trash.slash")
            }
        case .shared, .recents:
            EmptyView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if section == .myDrive {
            if FeatureFlags.uploadFiles {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showUpload = true
                    } label: {
                        Label("Upload", systemImage: "plus")
                    }
                }
            }
            if parentID == nil {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showCreateFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                }
            }
        }

        if section == .trash {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEmptyTrashConfirmation = true
                } label: {
                    Text("Empty Trash")
                        .foregroundStyle(.red)
                }
                .disabled(currentItems.isEmpty)
            }
        }
    }

    // MARK: - Download

    private func startDownload(for item: DriveItem) {
        Task {
            do {
                previewURL = try await downloadService.download(
                    fileID: item.id,
                    fileName: item.name,
                    mimeType: item.mimeType
                )
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    // MARK: - Offline

    private func toggleOffline(for item: DriveItem) {
        if offlineService.isOffline(fileID: item.id) {
            offlineService.removeOffline(fileID: item.id)
        } else {
            Task {
                do {
                    try await offlineService.makeAvailableOffline(item: item, downloadService: downloadService)
                } catch {
                    downloadError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: emptyStateIcon)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(emptyStateTitle)
                .font(.title2)
                .fontWeight(.semibold)
            Text(emptyStateSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var emptyStateIcon: String {
        switch section {
        case .myDrive: return "folder"
        case .starred: return "star"
        case .shared:  return "person.2"
        case .recents: return "clock"
        case .trash:   return "trash"
        }
    }

    private var emptyStateTitle: String {
        switch section {
        case .myDrive: return "No Files Here"
        case .starred: return "No Starred Items"
        case .shared:  return "Nothing Shared Yet"
        case .recents: return "No Recent Files"
        case .trash:   return "Trash is Empty"
        }
    }

    private var emptyStateSubtitle: String {
        switch section {
        case .myDrive: return "Tap the folder button to create your first folder."
        case .starred: return "Touch and hold a file or folder, then choose Add Star to keep it here."
        case .shared:  return "Files shared with you will appear here."
        case .recents: return "Files you open or modify will appear here."
        case .trash:   return "Deleted files are moved here before being permanently removed."
        }
    }
}

// MARK: - MyDriveSearchModifier

/// Applies `.searchable(text:)` only when `isEnabled` — keeps the search field scoped to the
/// My Drive list (gated by `FeatureFlags.search`) without affecting other sections.
private struct MyDriveSearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var searchText: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $searchText, prompt: "Search My Drive")
        } else {
            content
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FileBrowserView(section: .myDrive, parentID: nil)
            .environmentObject(DriveService())
            .environmentObject(AuthService())
            .environmentObject(OfflineService())
    }
}
