import XCTest
import CoreSpotlight
@testable import NeutrinoDrive

// MARK: - FakeSpotlightIndex

/// Records what *would* be written to CoreSpotlight.
///
/// The real `CSSearchableIndex` is a system daemon shared across the whole device: tests against
/// it would leave residue behind a run and could not observe their own writes. Since the entire
/// point of `SpotlightIndexService` is "never write the wrong thing", a test that could not
/// inspect the writes would be worthless.
final class FakeSpotlightIndex: SpotlightIndexing {
    private(set) var indexedItems: [CSSearchableItem] = []
    private(set) var deletedIdentifiers: [String] = []
    private(set) var deletedDomains: [String] = []

    func indexSearchableItems(_ items: [CSSearchableItem], completionHandler: ((Error?) -> Void)?) {
        indexedItems.append(contentsOf: items)
        completionHandler?(nil)
    }

    func deleteSearchableItems(withIdentifiers identifiers: [String], completionHandler: ((Error?) -> Void)?) {
        deletedIdentifiers.append(contentsOf: identifiers)
        completionHandler?(nil)
    }

    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String], completionHandler: ((Error?) -> Void)?) {
        deletedDomains.append(contentsOf: domainIdentifiers)
        completionHandler?(nil)
    }
}

// MARK: - SpotlightIndexServiceTests

/// Unit tests for `SpotlightIndexService`.
///
/// The tests that matter most here are the *negative* ones. CoreSpotlight's index is not
/// end-to-end encrypted, so this suite's job is to prove that nothing is written by default and
/// that no content-bearing attribute is ever populated — a future edit adding `textContent` for
/// "better search" would be a silent E2EE regression, and these assertions are what stop it.
@MainActor
final class SpotlightIndexServiceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var index: FakeSpotlightIndex!

    override func setUp() {
        super.setUp()
        suiteName = "nd.spotlight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        index = FakeSpotlightIndex()
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        index = nil
        super.tearDown()
    }

    private func makeService() -> SpotlightIndexService {
        SpotlightIndexService(defaults: defaults, index: index)
    }

    private func makeItem(id: String = "file-1", name: String = "Report.pdf",
                          type: DriveItem.ItemType = .file,
                          mimeType: String? = "application/pdf") -> DriveItem {
        DriveItem(id: id, name: name, type: type, parentID: nil, size: 1024,
                  modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                  isTrashed: false, isShared: false, mimeType: mimeType)
    }

    // MARK: - The default

    /// The single most important assertion in this file. An E2EE product that indexes filenames
    /// by default has volunteered them to a system-readable database without asking.
    func test_isEnabled_defaultsToFalse() {
        XCTAssertFalse(makeService().isEnabled)
    }

    func test_index_doesNothing_whenDisabled() {
        let sut = makeService()
        XCTAssertFalse(sut.isEnabled)

        sut.index(items: [makeItem()])

        XCTAssertTrue(index.indexedItems.isEmpty, "nothing may be indexed while opted out")
    }

    func test_index_writes_whenEnabled() {
        let sut = makeService()
        sut.isEnabled = true

        sut.index(items: [makeItem(name: "Report.pdf")])

        XCTAssertEqual(index.indexedItems.count, 1)
        XCTAssertEqual(index.indexedItems.first?.attributeSet.displayName, "Report.pdf")
    }

    /// The build flag is the outer gate and the user setting is the inner one; writing requires
    /// **both**.
    ///
    /// `FeatureFlags.spotlightSearch` is a `static let`, so a test cannot flip it and cannot
    /// observe the flag-off branch directly. What is asserted instead is the composition itself —
    /// that `isIndexingAllowed` tracks the flag rather than ignoring it — and that `index(items:)`
    /// consults `isIndexingAllowed` and nothing else. A skipped test was written here first and
    /// removed: a skip proves nothing and must never sit behind a ticked acceptance criterion.
    func test_isIndexingAllowed_requiresBothGates() {
        let sut = makeService()
        XCTAssertFalse(sut.isIndexingAllowed, "user setting off ⇒ not allowed")

        sut.isEnabled = true
        XCTAssertEqual(sut.isIndexingAllowed, FeatureFlags.spotlightSearch,
                       "with the user setting on, the build flag is the only remaining gate")
    }

    func test_index_writesOnlyWhenIndexingIsAllowed() {
        let sut = makeService()
        sut.isEnabled = true

        sut.index(items: [makeItem()])

        XCTAssertEqual(index.indexedItems.isEmpty, !sut.isIndexingAllowed,
                       "index(items:) must gate on isIndexingAllowed, which folds in the build flag")
    }

    // MARK: - Attribute contents

    /// `CSSearchableItemAttributeSet.textContent` would accept a document's full decrypted text.
    /// It is never populated, and this assertion is the guard rail.
    func test_attributeSet_containsNoTextContent() {
        let attributes = SpotlightIndexService.searchableItem(for: makeItem()).attributeSet
        XCTAssertNil(attributes.textContent)
    }

    func test_attributeSet_containsNoContentDescription() {
        let attributes = SpotlightIndexService.searchableItem(for: makeItem()).attributeSet
        XCTAssertNil(attributes.contentDescription)
    }

    /// A thumbnail is a render of decrypted bytes. Putting one in a system index would move
    /// actual file content outside the E2EE boundary.
    func test_attributeSet_containsNoThumbnailData() {
        let attributes = SpotlightIndexService.searchableItem(for: makeItem()).attributeSet
        XCTAssertNil(attributes.thumbnailData)
        XCTAssertNil(attributes.thumbnailURL)
    }

    func test_attributeSet_carriesDisplayNameAndType() {
        let attributes = SpotlightIndexService.searchableItem(for: makeItem(name: "Budget.pdf")).attributeSet

        XCTAssertEqual(attributes.displayName, "Budget.pdf")
        XCTAssertEqual(attributes.contentModificationDate, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func test_searchableItem_forFolder_usesFolderType() {
        let item = SpotlightIndexService.searchableItem(
            for: makeItem(id: "d1", name: "Docs", type: .folder, mimeType: nil)
        )
        XCTAssertEqual(item.attributeSet.displayName, "Docs")
    }

    // MARK: - Domain identifier

    /// Every item carries one domain identifier so a single call clears all of them, regardless
    /// of what was written or when. Without it, de-indexing would require remembering every ID
    /// ever indexed.
    func test_searchableItem_carriesDomainIdentifier() {
        let item = SpotlightIndexService.searchableItem(for: makeItem())
        XCTAssertEqual(item.domainIdentifier, SpotlightIndexService.domainIdentifier)
    }

    func test_deindexAll_usesDomainIdentifier() {
        makeService().deindexAll()
        XCTAssertEqual(index.deletedDomains, [SpotlightIndexService.domainIdentifier])
    }

    func test_deindex_mapsDriveIDsToPrefixedIdentifiers() {
        makeService().deindex(itemIDs: ["file-1", "file-2"])
        XCTAssertEqual(index.deletedIdentifiers,
                       [SpotlightIndexService.identifier(forDriveID: "file-1"),
                        SpotlightIndexService.identifier(forDriveID: "file-2")])
    }

    /// Opting out must remove what opting in wrote. An index that outlives the setting makes the
    /// toggle a lie.
    func test_setEnabled_false_triggersDeindex() {
        let sut = makeService()
        sut.isEnabled = true
        sut.index(items: [makeItem()])
        XCTAssertTrue(index.deletedDomains.isEmpty)

        sut.isEnabled = false

        XCTAssertEqual(index.deletedDomains, [SpotlightIndexService.domainIdentifier])
    }

    func test_setEnabled_persistsAcrossInstances() {
        let sut = makeService()
        sut.isEnabled = true

        XCTAssertTrue(makeService().isEnabled)
    }

    // MARK: - Deep linking

    func test_driveItemID_fromSpotlightActivity_returnsIdentifier() {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [
            CSSearchableItemActivityIdentifier: SpotlightIndexService.identifier(forDriveID: "file-42")
        ]

        XCTAssertEqual(SpotlightIndexService.driveItemID(from: activity), "file-42")
    }

    /// A Handoff activity or a universal link must not be misread as a file to open.
    func test_driveItemID_fromUnrelatedActivity_returnsNil() {
        let activity = NSUserActivity(activityType: "com.example.other")
        activity.userInfo = [CSSearchableItemActivityIdentifier: "nd.item.file-42"]

        XCTAssertNil(SpotlightIndexService.driveItemID(from: activity))
    }

    func test_driveItemID_withForeignIdentifier_returnsNil() {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: "someone.else.item-1"]

        XCTAssertNil(SpotlightIndexService.driveItemID(from: activity))
    }

    func test_driveItemID_withNoUserInfo_returnsNil() {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        XCTAssertNil(SpotlightIndexService.driveItemID(from: activity))
    }
}
