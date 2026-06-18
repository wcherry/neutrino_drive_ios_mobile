import SwiftUI

// MARK: - MoveSheet

/// Sheet showing a flat list of eligible destination folders. The user can
/// move an item to root or to any non-trashed folder that is not the item
/// itself and not a descendant of the item.
struct MoveSheet: View {

    // MARK: - Parameters

    let item: DriveItem
    let onConfirm: (String?) -> Void

    // MARK: - Environment

    @EnvironmentObject var driveService: DriveService
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var selectedParentID: String? = nil

    // MARK: - Computed

    /// All non-trashed, non-descendent folders that are not the item itself.
    private var eligibleFolders: [DriveItem] {
        driveService.allItems.filter { candidate in
            guard candidate.type == .folder else { return false }
            guard !candidate.isTrashed else { return false }
            guard candidate.id != item.id else { return false }
            // Prevent moving into a descendant of this item.
            if driveService.isDescendant(potentialChildID: candidate.id, ofFolderID: item.id) {
                return false
            }
            return true
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var isMoveDisabled: Bool {
        // Disable if destination is the same as the current parent.
        selectedParentID == item.parentID
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List(selection: $selectedParentID) {
                Section {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.blue)
                        Text("Root")
                        Spacer()
                        if selectedParentID == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedParentID = nil
                    }
                }

                Section("Folders") {
                    ForEach(eligibleFolders) { folder in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(folder.name)
                            Spacer()
                            if selectedParentID == folder.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedParentID = folder.id
                        }
                    }
                }
            }
            .navigationTitle("Move \(item.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        onConfirm(selectedParentID)
                        dismiss()
                    }
                    .disabled(isMoveDisabled)
                }
            }
            .onAppear {
                selectedParentID = item.parentID
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let service = DriveService()
    let item = service.allItems.first(where: { $0.type == .file }) ?? DriveItem(
        id: "preview",
        name: "Preview File.pdf",
        type: .file,
        parentID: nil,
        size: 1024,
        modifiedAt: Date(),
        isTrashed: false,
        isShared: false,
        mimeType: "application/pdf"
    )
    MoveSheet(item: item) { _ in }
        .environmentObject(service)
}
