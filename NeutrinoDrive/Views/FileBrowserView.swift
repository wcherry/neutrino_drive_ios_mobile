import SwiftUI

// MARK: - FileBrowserView

/// Displays the contents of a Drive section, supporting folder navigation,
/// swipe actions, context menus, and sheet presentation for mutations.
struct FileBrowserView: View {

    // MARK: - Parameters

    let section: DriveSection
    let parentID: String?

    // MARK: - Environment

    @EnvironmentObject var driveService: DriveService

    // MARK: - State

    @State private var showCreateFolder = false
    @State private var showUpload = false
    @State private var showEmptyTrashConfirmation = false
    @State private var itemToRename: DriveItem?
    @State private var itemToMove: DriveItem?

    // MARK: - Computed

    private var currentItems: [DriveItem] {
        driveService.items(in: section, parentID: parentID)
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
            if driveService.isLoading && currentItems.isEmpty {
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
    }

    @ViewBuilder
    private func fileRow(for item: DriveItem) -> some View {
        Group {
            if item.type == .folder {
                NavigationLink(value: item) {
                    FileRowView(item: item)
                }
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
        case .shared, .recents:
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
        case .shared, .recents:
            EmptyView()
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for item: DriveItem) -> some View {
        switch section {
        case .myDrive:
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
        case .shared:  return "person.2"
        case .recents: return "clock"
        case .trash:   return "trash"
        }
    }

    private var emptyStateTitle: String {
        switch section {
        case .myDrive: return "No Files Here"
        case .shared:  return "Nothing Shared Yet"
        case .recents: return "No Recent Files"
        case .trash:   return "Trash is Empty"
        }
    }

    private var emptyStateSubtitle: String {
        switch section {
        case .myDrive: return "Tap the folder button to create your first folder."
        case .shared:  return "Files shared with you will appear here."
        case .recents: return "Files you open or modify will appear here."
        case .trash:   return "Deleted files are moved here before being permanently removed."
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FileBrowserView(section: .myDrive, parentID: nil)
            .environmentObject(DriveService())
    }
}
