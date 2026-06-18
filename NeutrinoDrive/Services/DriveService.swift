import Foundation

// MARK: - DriveService

/// In-memory service managing the mock Neutrino Drive file system.
/// All mutations happen synchronously on the main actor and are reflected
/// immediately through the @Published `allItems` property.
@MainActor
final class DriveService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var allItems: [DriveItem]

    // MARK: - Init

    init() {
        allItems = Self.makeMockData()
    }

    // MARK: - Querying

    /// Returns items visible in the given section filtered by parentID.
    func items(in section: DriveSection, parentID: String?) -> [DriveItem] {
        switch section {
        case .myDrive:
            return allItems.filter { item in
                !item.isTrashed && item.parentID == parentID
            }
        case .shared:
            return allItems.filter { item in
                item.isShared && !item.isTrashed
            }
        case .recents:
            let sorted = allItems
                .filter { !$0.isTrashed }
                .sorted { $0.modifiedAt > $1.modifiedAt }
            return Array(sorted.prefix(20))
        case .trash:
            return allItems.filter { $0.isTrashed }
        }
    }

    // MARK: - Mutations

    /// Creates a new folder with the given name inside the specified parent.
    func createFolder(name: String, parentID: String?) {
        let folder = DriveItem(
            id: UUID().uuidString,
            name: name,
            type: .folder,
            parentID: parentID,
            size: nil,
            modifiedAt: Date(),
            isTrashed: false,
            isShared: false,
            mimeType: nil
        )
        allItems.append(folder)
    }

    /// Renames the item with the given id.
    func rename(itemID: String, to newName: String) {
        guard let index = allItems.firstIndex(where: { $0.id == itemID }) else { return }
        allItems[index].name = newName
        allItems[index].modifiedAt = Date()
    }

    /// Moves an item to Trash if it is not already there; permanently deletes it if it is.
    func delete(itemID: String) {
        guard let index = allItems.firstIndex(where: { $0.id == itemID }) else { return }
        if allItems[index].isTrashed {
            allItems.remove(at: index)
        } else {
            allItems[index].isTrashed = true
            allItems[index].modifiedAt = Date()
        }
    }

    /// Moves the item to a new parent folder. Silently ignores a move that would
    /// create an ancestry cycle (i.e. moving a folder into its own descendant).
    func move(itemID: String, to newParentID: String?) {
        guard let newParentID else {
            // Moving to root — safe as long as the item is not itself the root.
            if let index = allItems.firstIndex(where: { $0.id == itemID }) {
                allItems[index].parentID = nil
            }
            return
        }

        // Prevent cycle: moving a folder into one of its own descendants.
        if isDescendant(potentialChildID: newParentID, ofFolderID: itemID) { return }

        guard let index = allItems.firstIndex(where: { $0.id == itemID }) else { return }
        allItems[index].parentID = newParentID
    }

    /// Restores a trashed item back to its original location.
    func restore(itemID: String) {
        guard let index = allItems.firstIndex(where: { $0.id == itemID }) else { return }
        allItems[index].isTrashed = false
    }

    /// Permanently deletes every item currently in the Trash.
    func emptyTrash() {
        allItems.removeAll { $0.isTrashed }
    }

    // MARK: - Ancestry Helper

    /// Returns true when `potentialChildID` is a descendant of `folderID` by
    /// walking up the parentID chain.
    func isDescendant(potentialChildID: String, ofFolderID folderID: String) -> Bool {
        var currentID: String? = potentialChildID
        while let id = currentID {
            if id == folderID { return true }
            currentID = allItems.first(where: { $0.id == id })?.parentID
        }
        return false
    }

    // MARK: - Mock Data

    private static func makeMockData() -> [DriveItem] {
        let now = Date()
        let calendar = Calendar.current

        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: now) ?? now
        }

        // Root-level folders
        let documentsID = "folder-documents"
        let photosID    = "folder-photos"
        let projectsID  = "folder-projects"
        let archiveID   = "folder-archive"

        let folders: [DriveItem] = [
            DriveItem(
                id: documentsID,
                name: "Documents",
                type: .folder,
                parentID: nil,
                size: nil,
                modifiedAt: daysAgo(3),
                isTrashed: false,
                isShared: false,
                mimeType: nil
            ),
            DriveItem(
                id: photosID,
                name: "Photos",
                type: .folder,
                parentID: nil,
                size: nil,
                modifiedAt: daysAgo(1),
                isTrashed: false,
                isShared: false,
                mimeType: nil
            ),
            DriveItem(
                id: projectsID,
                name: "Projects",
                type: .folder,
                parentID: nil,
                size: nil,
                modifiedAt: daysAgo(5),
                isTrashed: false,
                isShared: false,
                mimeType: nil
            ),
            DriveItem(
                id: archiveID,
                name: "Archive",
                type: .folder,
                parentID: nil,
                size: nil,
                modifiedAt: daysAgo(30),
                isTrashed: false,
                isShared: false,
                mimeType: nil
            ),
        ]

        // Files spread across folders
        let files: [DriveItem] = [
            DriveItem(
                id: "file-report",
                name: "Q3 Report.pdf",
                type: .file,
                parentID: documentsID,
                size: 1_024_512,
                modifiedAt: daysAgo(2),
                isTrashed: false,
                isShared: false,
                mimeType: "application/pdf"
            ),
            DriveItem(
                id: "file-notes",
                name: "Meeting Notes.txt",
                type: .file,
                parentID: documentsID,
                size: 4_096,
                modifiedAt: daysAgo(1),
                isTrashed: false,
                isShared: true,
                mimeType: "text/plain"
            ),
            DriveItem(
                id: "file-vacation",
                name: "Vacation.jpg",
                type: .file,
                parentID: photosID,
                size: 3_145_728,
                modifiedAt: daysAgo(0),
                isTrashed: false,
                isShared: false,
                mimeType: "image/jpeg"
            ),
            DriveItem(
                id: "file-demo-video",
                name: "Demo.mp4",
                type: .file,
                parentID: projectsID,
                size: 52_428_800,
                modifiedAt: daysAgo(0),
                isTrashed: false,
                isShared: true,
                mimeType: "video/mp4"
            ),
            DriveItem(
                id: "file-backup",
                name: "Backup.zip",
                type: .file,
                parentID: archiveID,
                size: 10_485_760,
                modifiedAt: daysAgo(60),
                isTrashed: false,
                isShared: false,
                mimeType: "application/zip"
            ),
            DriveItem(
                id: "file-readme",
                name: "README.txt",
                type: .file,
                parentID: projectsID,
                size: 2_048,
                modifiedAt: daysAgo(7),
                isTrashed: false,
                isShared: false,
                mimeType: "text/plain"
            ),
        ]

        // Trashed item
        let trashed: [DriveItem] = [
            DriveItem(
                id: "file-old-draft",
                name: "Old Draft.pdf",
                type: .file,
                parentID: documentsID,
                size: 512_000,
                modifiedAt: daysAgo(14),
                isTrashed: true,
                isShared: false,
                mimeType: "application/pdf"
            ),
        ]

        return folders + files + trashed
    }
}
