import XCTest
import NeutrinoCore
import NeutrinoAuth
@testable import NeutrinoDrive

/// Unit tests for DriveService covering optimistic mutation logic and section queries.
/// Tests use the DEBUG seed initializer to pre-populate state without network calls.
@MainActor
final class DriveServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeFolder(id: String, name: String, parentID: String? = nil) -> DriveItem {
        DriveItem(id: id, name: name, type: .folder, parentID: parentID,
                  size: nil, modifiedAt: Date(), isTrashed: false, isShared: false, mimeType: nil)
    }

    private func makeFile(id: String, name: String, parentID: String? = nil,
                          mimeType: String = "text/plain") -> DriveItem {
        DriveItem(id: id, name: name, type: .file, parentID: parentID,
                  size: 1024, modifiedAt: Date(), isTrashed: false, isShared: false, mimeType: mimeType)
    }

    // MARK: - createFolder

    func test_createFolder_addsOptimisticPlaceholderToAllItems() {
        let sut = DriveService()
        sut.createFolder(name: "New Folder", parentID: nil)

        XCTAssertTrue(sut.allItems.contains(where: { $0.name == "New Folder" && $0.type == .folder }))
    }

    func test_createFolder_placeholderHasCorrectParentID() {
        let sut = DriveService()
        sut.createFolder(name: "Sub", parentID: "parent-id")

        let created = sut.allItems.first(where: { $0.name == "Sub" })
        XCTAssertEqual(created?.parentID, "parent-id")
    }

    func test_createFolder_placeholderIsNotTrashed() {
        let sut = DriveService()
        sut.createFolder(name: "Clean", parentID: nil)

        XCTAssertEqual(sut.allItems.first(where: { $0.name == "Clean" })?.isTrashed, false)
    }

    func test_createFolder_appearsInMyDriveSection() {
        let sut = DriveService()
        sut.createFolder(name: "Root Folder", parentID: nil)

        let visible = sut.items(in: .myDrive, parentID: nil)
        XCTAssertTrue(visible.contains(where: { $0.name == "Root Folder" }))
    }

    // MARK: - rename

    func test_rename_updatesNameImmediately() {
        let file = makeFile(id: "f1", name: "Original")
        let sut = DriveService(myDrive: [file])

        sut.rename(itemID: "f1", to: "Renamed")

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "f1" })?.name, "Renamed")
    }

    func test_rename_updatesModifiedAt() {
        let old = Date(timeIntervalSince1970: 0)
        var file = makeFile(id: "f1", name: "Old")
        file.modifiedAt = old
        let sut = DriveService(myDrive: [file])

        sut.rename(itemID: "f1", to: "New")

        let updated = sut.allItems.first(where: { $0.id == "f1" })
        XCTAssertGreaterThan(updated?.modifiedAt ?? old, old)
    }

    func test_rename_unknownID_doesNothing() {
        let sut = DriveService()
        let before = sut.allItems.count

        sut.rename(itemID: "ghost", to: "Anything")

        XCTAssertEqual(sut.allItems.count, before)
    }

    // MARK: - delete (soft — move to Trash)

    func test_delete_nonTrashedFile_removesFromAllItems() {
        let file = makeFile(id: "f1", name: "Doc")
        let sut = DriveService(myDrive: [file])

        sut.delete(itemID: "f1")

        XCTAssertNil(sut.allItems.first(where: { $0.id == "f1" }))
    }

    func test_delete_nonTrashedFile_addsToTrashItems() {
        let file = makeFile(id: "f1", name: "Doc")
        let sut = DriveService(myDrive: [file])

        sut.delete(itemID: "f1")

        XCTAssertTrue(sut.trashItems.contains(where: { $0.id == "f1" && $0.isTrashed }))
    }

    func test_delete_nonTrashedFile_noLongerAppearsInMyDriveSection() {
        let file = makeFile(id: "f1", name: "Doc", parentID: nil)
        let sut = DriveService(myDrive: [file])

        sut.delete(itemID: "f1")

        XCTAssertFalse(sut.items(in: .myDrive, parentID: nil).contains(where: { $0.id == "f1" }))
    }

    func test_delete_nonTrashedFile_appearsInTrashSection() {
        let file = makeFile(id: "f1", name: "Doc", parentID: nil)
        let sut = DriveService(myDrive: [file])

        sut.delete(itemID: "f1")

        XCTAssertTrue(sut.items(in: .trash, parentID: nil).contains(where: { $0.id == "f1" }))
    }

    // MARK: - delete (hard — already in Trash)

    func test_delete_alreadyTrashedItem_removesFromTrashItems() {
        var trashed = makeFile(id: "f1", name: "Old")
        trashed.isTrashed = true
        let sut = DriveService(trash: [trashed])

        sut.delete(itemID: "f1")

        XCTAssertFalse(sut.trashItems.contains(where: { $0.id == "f1" }))
    }

    func test_delete_softThenHard_fullyRemovesItem() {
        let file = makeFile(id: "f1", name: "Doc")
        let sut = DriveService(myDrive: [file])

        sut.delete(itemID: "f1")   // soft
        sut.delete(itemID: "f1")   // hard

        XCTAssertFalse(sut.allItems.contains(where: { $0.id == "f1" }))
        XCTAssertFalse(sut.trashItems.contains(where: { $0.id == "f1" }))
    }

    // MARK: - move

    func test_move_changesParentID() {
        let file = makeFile(id: "f1", name: "Doc", parentID: "folder-a")
        let dest = makeFolder(id: "folder-b", name: "B")
        let sut = DriveService(myDrive: [file, dest])

        sut.move(itemID: "f1", to: "folder-b")

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "f1" })?.parentID, "folder-b")
    }

    func test_move_toRoot_setsParentIDNil() {
        let file = makeFile(id: "f1", name: "Doc", parentID: "folder-a")
        let sut = DriveService(myDrive: [file])

        sut.move(itemID: "f1", to: nil)

        XCTAssertNil(sut.allItems.first(where: { $0.id == "f1" })?.parentID)
    }

    func test_move_folderIntoOwnDescendant_isIgnored() {
        let parent = makeFolder(id: "p", name: "Parent")
        var child = makeFolder(id: "c", name: "Child", parentID: "p")
        let sut = DriveService(myDrive: [parent, child])

        sut.move(itemID: "p", to: "c")

        // Parent's parentID must not have changed.
        XCTAssertEqual(sut.allItems.first(where: { $0.id == "p" })?.parentID, parent.parentID)
    }

    // MARK: - restore

    func test_restore_movesItemFromTrashToAllItems() {
        var trashed = makeFile(id: "f1", name: "Doc")
        trashed.isTrashed = true
        let sut = DriveService(trash: [trashed])

        sut.restore(itemID: "f1")

        XCTAssertNotNil(sut.allItems.first(where: { $0.id == "f1" }))
        XCTAssertFalse(sut.trashItems.contains(where: { $0.id == "f1" }))
    }

    func test_restore_restoredItemIsNotTrashed() {
        var trashed = makeFile(id: "f1", name: "Doc")
        trashed.isTrashed = true
        let sut = DriveService(trash: [trashed])

        sut.restore(itemID: "f1")

        XCTAssertEqual(sut.allItems.first(where: { $0.id == "f1" })?.isTrashed, false)
    }

    func test_restore_unknownID_doesNothing() {
        let sut = DriveService()
        sut.restore(itemID: "ghost")
        XCTAssertTrue(sut.allItems.isEmpty)
        XCTAssertTrue(sut.trashItems.isEmpty)
    }

    // MARK: - emptyTrash

    func test_emptyTrash_clearsAllTrashItems() {
        var t1 = makeFile(id: "f1", name: "A"); t1.isTrashed = true
        var t2 = makeFolder(id: "d1", name: "B"); t2.isTrashed = true
        let sut = DriveService(trash: [t1, t2])

        sut.emptyTrash()

        XCTAssertTrue(sut.trashItems.isEmpty)
    }

    func test_emptyTrash_doesNotAffectMyDriveItems() {
        let file = makeFile(id: "f1", name: "Keep")
        var trashed = makeFile(id: "f2", name: "Remove"); trashed.isTrashed = true
        let sut = DriveService(myDrive: [file], trash: [trashed])

        sut.emptyTrash()

        XCTAssertTrue(sut.allItems.contains(where: { $0.id == "f1" }))
    }

    // MARK: - isDescendant

    func test_isDescendant_directChild_returnsTrue() {
        let parent = makeFolder(id: "p", name: "Parent")
        let child = makeFolder(id: "c", name: "Child", parentID: "p")
        let sut = DriveService(myDrive: [parent, child])

        XCTAssertTrue(sut.isDescendant(potentialChildID: "c", ofFolderID: "p"))
    }

    func test_isDescendant_grandchild_returnsTrue() {
        let gp = makeFolder(id: "gp", name: "Grandparent")
        let p  = makeFolder(id: "p",  name: "Parent",     parentID: "gp")
        let c  = makeFolder(id: "c",  name: "Child",      parentID: "p")
        let sut = DriveService(myDrive: [gp, p, c])

        XCTAssertTrue(sut.isDescendant(potentialChildID: "c", ofFolderID: "gp"))
    }

    func test_isDescendant_unrelated_returnsFalse() {
        let a = makeFolder(id: "a", name: "A")
        let b = makeFolder(id: "b", name: "B")
        let sut = DriveService(myDrive: [a, b])

        XCTAssertFalse(sut.isDescendant(potentialChildID: "b", ofFolderID: "a"))
    }

    func test_isDescendant_self_returnsTrue() {
        let folder = makeFolder(id: "x", name: "X")
        let sut = DriveService(myDrive: [folder])

        // Self is treated as a descendant so "move folder into itself" is rejected.
        XCTAssertTrue(sut.isDescendant(potentialChildID: "x", ofFolderID: "x"))
    }

    // MARK: - items(in:parentID:)

    func test_items_myDrive_filtersByParentID() {
        let root = makeFolder(id: "f1", name: "Root", parentID: nil)
        let sub  = makeFile(id: "f2",   name: "Sub",  parentID: "folder-a")
        let sut  = DriveService(myDrive: [root, sub])

        let rootItems = sut.items(in: .myDrive, parentID: nil)
        XCTAssertTrue(rootItems.contains(where: { $0.id == "f1" }))
        XCTAssertFalse(rootItems.contains(where: { $0.id == "f2" }))
    }

    func test_items_trash_returnsTrashItems() {
        var t = makeFile(id: "t1", name: "Trashed"); t.isTrashed = true
        let sut = DriveService(trash: [t])

        let result = sut.items(in: .trash, parentID: nil)
        XCTAssertTrue(result.contains(where: { $0.id == "t1" }))
    }

    func test_items_recents_returnsRecentItems() {
        let recent = makeFile(id: "r1", name: "Recent")
        let sut = DriveService(recents: [recent])

        XCTAssertTrue(sut.items(in: .recents, parentID: nil).contains(where: { $0.id == "r1" }))
    }

    func test_items_shared_returnsSharedItems() {
        let shared = makeFile(id: "s1", name: "Shared")
        let sut = DriveService(shared: [shared])

        XCTAssertTrue(sut.items(in: .shared, parentID: nil).contains(where: { $0.id == "s1" }))
    }

    // MARK: - fileWasUploaded — unloaded-parent guard (photo-sync uploads)

    /// A background photo-sync upload into a folder the user has never opened must not
    /// insert a lone child — the file browser has no way to know it's showing a partial
    /// listing. See PhotoSyncService / UploadService refactor plan.
    func test_fileWasUploaded_doesNotAppend_intoUnloadedParentFolder() {
        let sut = DriveService()   // fresh instance — loadSection was never called
        let result = UploadResult(id: "u1", name: "photo.jpg", folderId: "never-opened-folder",
                                  sizeBytes: 100, mimeType: "image/jpeg", updatedAt: Date())

        sut.fileWasUploaded(result)

        XCTAssertFalse(sut.allItems.contains(where: { $0.id == "u1" }))
    }

    func test_fileWasUploaded_appends_onceParentHasBeenLoaded() {
        let sut = DriveService()
        sut.debugMarkLoaded(parentID: "opened-folder")
        let result = UploadResult(id: "u2", name: "photo.jpg", folderId: "opened-folder",
                                  sizeBytes: 100, mimeType: "image/jpeg", updatedAt: Date())

        sut.fileWasUploaded(result)

        XCTAssertTrue(sut.allItems.contains(where: { $0.id == "u2" }))
    }

    func test_fileWasUploaded_appendsToRoot_whenSeededWithRootItems() {
        // The DEBUG convenience init marks root (nil) as loaded whenever it's used, matching
        // real app behaviour where root is fetched before any upload UI is reachable.
        let sut = DriveService(myDrive: [])
        let result = UploadResult(id: "u3", name: "photo.jpg", folderId: nil,
                                  sizeBytes: 100, mimeType: "image/jpeg", updatedAt: Date())

        sut.fileWasUploaded(result)

        XCTAssertTrue(sut.allItems.contains(where: { $0.id == "u3" }))
    }

    // MARK: - ensureFolder

    func test_ensureFolder_adoptsExistingCaseInsensitiveMatch_insteadOfCreatingDuplicate() async throws {
        KeychainService.save(TestJWT.make(), forKey: AuthService.accessTokenKey)
        defer { KeychainService.delete(forKey: AuthService.accessTokenKey) }

        var requestCount = 0
        var lastMethod: String?
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            lastMethod = request.httpMethod
            let json = """
            {"files": [], "folders": [{"id": "existing-id", "name": "iPhone photos", "parentId": null, "updatedAt": "2024-01-01T00:00:00"}]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json)
        }
        defer { MockURLProtocol.reset() }

        let sut = DriveService(session: MockURLProtocol.makeSession())
        let folderID = try await sut.ensureFolder(named: "iPhone Photos", parentID: nil)

        XCTAssertEqual(folderID, "existing-id")
        XCTAssertEqual(requestCount, 1, "only the lookup GET should fire — no POST (create) when a match already exists")
        XCTAssertEqual(lastMethod, "GET")
    }

    func test_ensureFolder_createsNewFolder_whenNoMatchExists() async throws {
        KeychainService.save(TestJWT.make(), forKey: AuthService.accessTokenKey)
        defer { KeychainService.delete(forKey: AuthService.accessTokenKey) }

        var methods: [String] = []
        MockURLProtocol.requestHandler = { request in
            methods.append(request.httpMethod ?? "?")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.httpMethod == "GET" {
                let json = """
                {"files": [], "folders": []}
                """.data(using: .utf8)!
                return (response, json)
            } else {
                let json = """
                {"id": "new-id", "name": "iPhone Photos", "parentId": null, "updatedAt": "2024-01-01T00:00:00"}
                """.data(using: .utf8)!
                return (response, json)
            }
        }
        defer { MockURLProtocol.reset() }

        let sut = DriveService(session: MockURLProtocol.makeSession())
        let folderID = try await sut.ensureFolder(named: "iPhone Photos", parentID: nil)

        XCTAssertEqual(folderID, "new-id")
        XCTAssertEqual(methods, ["GET", "POST"])
    }
}
