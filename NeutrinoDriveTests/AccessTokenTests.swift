import XCTest
@testable import NeutrinoDrive

/// Tests for `AccessToken` and the listing path it feeds.
///
/// The root listing is the reason this type exists: `GET /api/v1/drive` was folded into
/// `/drive/folders/{id}` server-side, where the id of a user's root folder is their own user id.
/// Getting that wrong is silent — the app browses an empty drive rather than failing loudly — so
/// both shapes are pinned here.
@MainActor
final class AccessTokenTests: XCTestCase {

    private func makeToken(sub: String) -> String { TestJWT.make(sub: sub) }

    override func tearDown() {
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        super.tearDown()
    }

    // MARK: - Claims

    func test_currentUserID_readsTheSubClaim() {
        KeychainService.save(makeToken(sub: "user-42"), forKey: AuthService.accessTokenKey)

        XCTAssertEqual(AccessToken.currentUserID(), "user-42")
    }

    func test_currentUserID_isNilWhenSignedOut() {
        KeychainService.delete(forKey: AuthService.accessTokenKey)

        XCTAssertNil(AccessToken.currentUserID())
    }

    func test_currentUserID_isNilForAnUnreadableToken() {
        for token in ["", "not-a-jwt", "header.!!!not-base64!!!.signature", "header.e30.signature"] {
            KeychainService.save(token, forKey: AuthService.accessTokenKey)
            XCTAssertNil(AccessToken.currentUserID(), "for \(token)")
        }
    }

    // MARK: - Listing path

    func test_folderContentsPath_namesTheUserForTheRoot() throws {
        KeychainService.save(makeToken(sub: "user-42"), forKey: AuthService.accessTokenKey)
        let sut = DriveService()

        XCTAssertEqual(try sut.folderContentsPath(parentID: nil),
                       "/api/v1/drive/folders/user-42")
    }

    func test_folderContentsPath_namesTheFolderForEverythingElse() throws {
        KeychainService.save(makeToken(sub: "user-42"), forKey: AuthService.accessTokenKey)
        let sut = DriveService()

        XCTAssertEqual(try sut.folderContentsPath(parentID: "folder-9"),
                       "/api/v1/drive/folders/folder-9")
    }

    /// The bare `/api/v1/drive` this used to request no longer exists on the server. A test that
    /// only checked the folder case would have passed throughout.
    func test_folderContentsPath_neverRequestsTheRemovedRootRoute() throws {
        KeychainService.save(makeToken(sub: "user-42"), forKey: AuthService.accessTokenKey)
        let sut = DriveService()

        for parentID in [nil, "folder-9"] {
            XCTAssertNotEqual(try sut.folderContentsPath(parentID: parentID), "/api/v1/drive")
        }
    }

    func test_folderContentsPath_refusesTheRootWhenSignedOut() {
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        let sut = DriveService()

        XCTAssertThrowsError(try sut.folderContentsPath(parentID: nil)) { error in
            guard case DriveError.notAuthenticated = error else {
                return XCTFail("Expected notAuthenticated, got \(error)")
            }
        }
    }
}
