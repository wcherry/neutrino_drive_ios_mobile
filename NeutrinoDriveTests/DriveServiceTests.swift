import XCTest
@testable import NeutrinoDrive

/// Unit tests for DriveService covering all mutation methods and query helpers.
///
/// The service is @MainActor, so the test class is also @MainActor to ensure
/// all interactions with published state happen on the main thread.
@MainActor
final class DriveServiceTests: XCTestCase {

    // MARK: - Subject Under Test

    private var sut: DriveService!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        sut = DriveService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - createFolder

    func test_createFolder_addsNewFolderVisibleInMyDriveRoot() {
        let beforeCount = sut.items(in: .myDrive, parentID: nil).count

        sut.createFolder(name: "New Folder", parentID: nil)

        let afterItems = sut.items(in: .myDrive, parentID: nil)
        XCTAssertEqual(afterItems.count, beforeCount + 1)
        XCTAssertTrue(afterItems.contains(where: { $0.name == "New Folder" && $0.type == .folder }))
    }

    func test_createFolder_newFolderHasCorrectParentID() {
        let parentID = "folder-documents"

        sut.createFolder(name: "Sub Folder", parentID: parentID)

        let created = sut.allItems.first(where: { $0.name == "Sub Folder" && $0.type == .folder })
        XCTAssertNotNil(created)
        XCTAssertEqual(created?.parentID, parentID)
    }

    func test_createFolder_newFolderIsNotTrashed() {
        sut.createFolder(name: "Clean Folder", parentID: nil)

        let created = sut.allItems.first(where: { $0.name == "Clean Folder" })
        XCTAssertEqual(created?.isTrashed, false)
    }

    // MARK: - rename

    func test_rename_updatesItemName() throws {
        let target = try XCTUnwrap(sut.allItems.first(where: { $0.type == .file }))

        sut.rename(itemID: target.id, to: "Renamed File")

        let updated = sut.allItems.first(where: { $0.id == target.id })
        XCTAssertEqual(updated?.name, "Renamed File")
    }

    func test_rename_updatesModifiedAt() throws {
        let target = try XCTUnwrap(sut.allItems.first(where: { $0.type == .file }))
        let beforeDate = target.modifiedAt

        sut.rename(itemID: target.id, to: "New Name")

        let updated = sut.allItems.first(where: { $0.id == target.id })
        XCTAssertNotNil(updated?.modifiedAt)
        XCTAssertGreaterThanOrEqual(updated?.modifiedAt ?? beforeDate, beforeDate)
    }

    func test_rename_withUnknownID_doesNothing() {
        let countBefore = sut.allItems.count

        sut.rename(itemID: "non-existent-id", to: "Ghost")

        XCTAssertEqual(sut.allItems.count, countBefore)
    }

    // MARK: - delete (to Trash)

    func test_delete_fromMyDrive_movesItemToTrash() throws {
        let target = try XCTUnwrap(sut.allItems.first(where: { !$0.isTrashed }))

        sut.delete(itemID: target.id)

        let updated = sut.allItems.first(where: { $0.id == target.id })
        XCTAssertNotNil(updated, "Item must still exist in allItems after soft delete")
        XCTAssertEqual(updated?.isTrashed, true)
    }

    func test_delete_fromMyDrive_itemRemovedFromMyDriveSection() throws {
        // Files live inside folders; grab one from any folder to ensure we get a non-nil result.
        let target = try XCTUnwrap(
            sut.allItems.first(where: { $0.type == .file && !$0.isTrashed })
        )

        sut.delete(itemID: target.id)

        // After soft-delete the item must not appear in its original folder's listing.
        let folderItems = sut.items(in: .myDrive, parentID: target.parentID)
        XCTAssertFalse(folderItems.contains(where: { $0.id == target.id }))
    }

    func test_delete_fromMyDrive_itemAppearsInTrashSection() throws {
        let target = try XCTUnwrap(
            sut.items(in: .myDrive, parentID: nil).first(where: { $0.type == .folder })
        )

        sut.delete(itemID: target.id)

        let trashItems = sut.items(in: .trash, parentID: nil)
        XCTAssertTrue(trashItems.contains(where: { $0.id == target.id }))
    }

    // MARK: - delete (permanent from Trash)

    func test_delete_fromTrash_permanentlyRemovesItemFromAllItems() throws {
        let target = try XCTUnwrap(sut.allItems.first(where: { $0.isTrashed }))

        sut.delete(itemID: target.id)

        XCTAssertNil(sut.allItems.first(where: { $0.id == target.id }), "Trashed item must be permanently removed")
    }

    func test_delete_softThenHard_permanentlyRemovesItem() throws {
        let target = try XCTUnwrap(sut.allItems.first(where: { !$0.isTrashed }))

        sut.delete(itemID: target.id)   // soft delete → isTrashed = true
        sut.delete(itemID: target.id)   // hard delete → removed from allItems

        XCTAssertNil(sut.allItems.first(where: { $0.id == target.id }))
    }

    // MARK: - move

    func test_move_changesParentID() throws {
        let file = try XCTUnwrap(sut.allItems.first(where: { $0.type == .file && !$0.isTrashed }))
        let destinationFolder = try XCTUnwrap(
            sut.allItems.first(where: { $0.type == .folder && $0.id != file.parentID && !$0.isTrashed })
        )

        sut.move(itemID: file.id, to: destinationFolder.id)

        let updated = sut.allItems.first(where: { $0.id == file.id })
        XCTAssertEqual(updated?.parentID, destinationFolder.id)
    }

    func test_move_toRoot_setsParentIDNil() throws {
        let file = try XCTUnwrap(sut.allItems.first(where: { $0.type == .file && $0.parentID != nil }))

        sut.move(itemID: file.id, to: nil)

        let updated = sut.allItems.first(where: { $0.id == file.id })
        XCTAssertNil(updated?.parentID)
    }

    func test_move_folderIntoOwnDescendant_doesNothing() throws {
        // Create a parent folder and a child folder.
        sut.createFolder(name: "Parent", parentID: nil)
        let parent = try XCTUnwrap(sut.allItems.first(where: { $0.name == "Parent" }))
        let originalParentID = parent.parentID

        sut.createFolder(name: "Child", parentID: parent.id)
        let child = try XCTUnwrap(sut.allItems.first(where: { $0.name == "Child" }))

        // Attempt to move parent into child — this would create a cycle.
        sut.move(itemID: parent.id, to: child.id)

        let unchanged = sut.allItems.first(where: { $0.id == parent.id })
        XCTAssertEqual(unchanged?.parentID, originalParentID, "Cycle-creating move must be rejected")
    }

    // MARK: - restore

    func test_restore_setsTrashedFlagFalse() throws {
        let target = try XCTUnwrap(sut.allItems.first(where: { $0.isTrashed }))

        sut.restore(itemID: target.id)

        let updated = sut.allItems.first(where: { $0.id == target.id })
        XCTAssertEqual(updated?.isTrashed, false)
    }

    func test_restore_itemDisappearsFromTrashSection() throws {
        let target = try XCTUnwrap(sut.allItems.first(where: { $0.isTrashed }))

        sut.restore(itemID: target.id)

        let trashItems = sut.items(in: .trash, parentID: nil)
        XCTAssertFalse(trashItems.contains(where: { $0.id == target.id }))
    }

    // MARK: - emptyTrash

    func test_emptyTrash_removesAllTrashedItemsFromAllItems() {
        // Ensure there is at least one trashed item.
        sut.delete(itemID: sut.allItems.first(where: { !$0.isTrashed })!.id)

        sut.emptyTrash()

        XCTAssertFalse(sut.allItems.contains(where: { $0.isTrashed }))
    }

    func test_emptyTrash_doesNotAffectNonTrashedItems() {
        let nonTrashedCountBefore = sut.allItems.filter { !$0.isTrashed }.count

        sut.emptyTrash()

        let nonTrashedCountAfter = sut.allItems.filter { !$0.isTrashed }.count
        XCTAssertEqual(nonTrashedCountAfter, nonTrashedCountBefore)
    }

    func test_emptyTrash_trashSectionBecomesEmpty() {
        sut.emptyTrash()

        XCTAssertTrue(sut.items(in: .trash, parentID: nil).isEmpty)
    }

    // MARK: - isDescendant

    func test_isDescendant_directChild_returnsTrue() throws {
        let parent = try XCTUnwrap(sut.allItems.first(where: { $0.type == .folder && !$0.isTrashed }))
        sut.createFolder(name: "DirectChild", parentID: parent.id)
        let child = try XCTUnwrap(sut.allItems.first(where: { $0.name == "DirectChild" }))

        XCTAssertTrue(sut.isDescendant(potentialChildID: child.id, ofFolderID: parent.id))
    }

    func test_isDescendant_grandchild_returnsTrue() throws {
        let grandparent = try XCTUnwrap(sut.allItems.first(where: { $0.type == .folder && !$0.isTrashed }))
        sut.createFolder(name: "ChildLevel", parentID: grandparent.id)
        let child = try XCTUnwrap(sut.allItems.first(where: { $0.name == "ChildLevel" }))
        sut.createFolder(name: "GrandchildLevel", parentID: child.id)
        let grandchild = try XCTUnwrap(sut.allItems.first(where: { $0.name == "GrandchildLevel" }))

        XCTAssertTrue(sut.isDescendant(potentialChildID: grandchild.id, ofFolderID: grandparent.id))
    }

    func test_isDescendant_unrelated_returnsFalse() throws {
        let folders = sut.allItems.filter { $0.type == .folder && !$0.isTrashed }
        guard folders.count >= 2 else {
            XCTSkip("Need at least two folders for this test")
            return
        }
        let folderA = folders[0]
        let folderB = folders[1]

        XCTAssertFalse(sut.isDescendant(potentialChildID: folderB.id, ofFolderID: folderA.id))
    }

    // MARK: - items(in:parentID:)

    func test_items_myDrive_excludesTrashedItems() {
        let allTrashed = sut.items(in: .myDrive, parentID: nil).filter { $0.isTrashed }
        XCTAssertTrue(allTrashed.isEmpty)
    }

    func test_items_shared_onlyIncludesSharedItems() {
        let shared = sut.items(in: .shared, parentID: nil)
        XCTAssertTrue(shared.allSatisfy({ $0.isShared }))
    }

    func test_items_recents_sortedDescending() {
        let recents = sut.items(in: .recents, parentID: nil)
        guard recents.count > 1 else { return }
        for index in 0..<recents.count - 1 {
            XCTAssertGreaterThanOrEqual(recents[index].modifiedAt, recents[index + 1].modifiedAt)
        }
    }

    func test_items_recents_maxTwenty() {
        // Add enough items to push over 20.
        for index in 0..<25 {
            sut.createFolder(name: "Bulk \(index)", parentID: nil)
        }
        let recents = sut.items(in: .recents, parentID: nil)
        XCTAssertLessThanOrEqual(recents.count, 20)
    }

    func test_items_trash_onlyIncludesTrashedItems() {
        let trash = sut.items(in: .trash, parentID: nil)
        XCTAssertTrue(trash.allSatisfy({ $0.isTrashed }))
    }
}
