import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import os.log

// MARK: - SpotlightIndexService

/// Indexes Drive **metadata** into CoreSpotlight, so file and folder names are findable from
/// system-wide search — behind a user setting that is **off by default**.
///
/// ## The privacy decision, and why the default is off
///
/// This is an end-to-end-encrypted product, and CoreSpotlight's index is **not** end-to-end
/// encrypted. It is a system database: readable by the system, included in device backups, and
/// used to serve Siri Suggestions and system search surfaces. Anything written here has left the
/// E2EE boundary. That is not a bug in Spotlight — it is what an index is — but it means the
/// question "should we index?" cannot be answered with "it's only metadata".
///
/// The tempting reading is that filenames are harmless. For this product they are not.
/// `Divorce settlement.pdf`, `HIV results.pdf`, `Layoff list Q3.xlsx`, a client's name in a
/// filename — these are frequently the most sensitive thing about a file, and a threat model
/// that encrypts the bytes while volunteering the names to a system index is incoherent. A user
/// who chose an E2EE drive did not implicitly consent to that.
///
/// So there are two independent gates:
///
/// - `FeatureFlags.spotlightSearch` — the build-level kill switch.
/// - ``isEnabled`` — the user setting, **default `false`**. Nothing is ever written until
///   somebody deliberately turns it on, having read what the Settings screen says.
///
/// ## What is indexed, and what is categorically not
///
/// Written: `displayName`, `contentType`, `contentModificationDate`, and a `domainIdentifier`.
/// That is the whole set.
///
/// **Never** written: file contents, decrypted plaintext, `textContent`, `contentDescription`,
/// or a `thumbnailData` rendered from decrypted bytes. `CSSearchableItemAttributeSet` will
/// happily accept all of those; none of them is populated, and `SpotlightIndexServiceTests`
/// asserts each stays nil so a future edit cannot quietly add one.
///
/// ## The caveat that keeps this honest
///
/// **Turning this off does not stop the system from seeing filenames.** Items vended by the File
/// Provider extension are displayed and searched by the Files app, and the system indexes
/// materialized items under its own policy. This setting governs *Neutrino's own*
/// `CSSearchableIndex` writes and nothing more. The Settings copy says exactly that — a privacy
/// control that overstates its reach is worse than no control, because it gets trusted.
@MainActor
final class SpotlightIndexService: ObservableObject {

    // MARK: - Constants

    /// One domain identifier for every item, so a single `deleteSearchableItems` call clears
    /// everything regardless of what was written or when.
    static let domainIdentifier = "com.neutrino.drive.items"

    /// Prefix on `CSSearchableItem.uniqueIdentifier`, so a Spotlight activity can be told apart
    /// from any other `NSUserActivity` the app might handle.
    static let identifierPrefix = "nd.item."

    static let enabledDefaultsKey = "nd.spotlight.enabled"

    // MARK: - Published State

    /// Whether the user has opted in. **Defaults to `false`** — `UserDefaults.bool(forKey:)`
    /// returns `false` for an absent key, which is the safe direction here and is asserted by a
    /// test rather than left to that coincidence.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if !isEnabled {
                // Opting out must remove what opting in wrote. An index that outlives the
                // setting would make the toggle a lie.
                deindexAll()
            }
        }
    }

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let index: SpotlightIndexing

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "SpotlightIndexService")

    init(defaults: UserDefaults = .standard, index: SpotlightIndexing? = nil) {
        self.defaults = defaults
        self.index = index ?? CoreSpotlightIndex()
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    // MARK: - Gate

    /// Both gates, in one place. Writing is allowed only when the build flag is on **and** the
    /// user opted in.
    var isIndexingAllowed: Bool {
        FeatureFlags.spotlightSearch && isEnabled
    }

    // MARK: - Index

    func index(items: [DriveItem]) {
        guard isIndexingAllowed else {
            logger.debug("index: skipped — indexing not allowed")
            return
        }
        let searchable = items.map { Self.searchableItem(for: $0) }
        index.indexSearchableItems(searchable) { [weak self] error in
            if let error {
                self?.logger.error("indexSearchableItems failed: \(error, privacy: .public)")
            }
        }
    }

    func deindex(itemIDs: [String]) {
        guard FeatureFlags.spotlightSearch else { return }
        let identifiers = itemIDs.map { Self.identifier(forDriveID: $0) }
        index.deleteSearchableItems(withIdentifiers: identifiers) { [weak self] error in
            if let error {
                self?.logger.error("deleteSearchableItems failed: \(error, privacy: .public)")
            }
        }
    }

    /// Removes every item this app indexed. Called on logout, on key removal, and on opting out.
    func deindexAll() {
        guard FeatureFlags.spotlightSearch else { return }
        logger.debug("deindexAll")
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { [weak self] error in
            if let error {
                self?.logger.error("deleteSearchableItems(domain:) failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Item construction

    static func identifier(forDriveID id: String) -> String {
        identifierPrefix + id
    }

    /// Resolve a Drive item ID out of a Spotlight `NSUserActivity`.
    ///
    /// Returns `nil` for any activity that is not one of ours, so an unrelated continuation —
    /// a Handoff activity, a universal link — cannot be misread as a file to open.
    static func driveItemID(from activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              identifier.hasPrefix(identifierPrefix) else {
            return nil
        }
        let id = String(identifier.dropFirst(identifierPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Build the searchable item for a Drive item.
    ///
    /// Static and pure so the *contents* of the attribute set can be asserted directly. The
    /// tests check both that the metadata fields are populated and — more importantly — that
    /// every content-bearing field is still nil.
    static func searchableItem(for item: DriveItem) -> CSSearchableItem {
        let type: UTType = item.type == .folder
            ? .folder
            : FileProviderItem.contentType(forMIME: item.mimeType, filename: item.name)

        let attributes = CSSearchableItemAttributeSet(contentType: type)

        // ── Metadata only. Everything written here is deliberate and enumerable. ──
        attributes.displayName = item.name
        attributes.contentModificationDate = item.modifiedAt

        // ── Deliberately NOT set, and asserted nil by SpotlightIndexServiceTests: ──
        //    textContent, contentDescription, thumbnailData, thumbnailURL.
        //    These are the fields that would carry decrypted content or a render of it into a
        //    system-readable index. None of them is appropriate for an E2EE product.

        let searchable = CSSearchableItem(
            uniqueIdentifier: identifier(forDriveID: item.id),
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        return searchable
    }
}

// MARK: - SpotlightIndexing

/// The slice of `CSSearchableIndex` this service uses.
///
/// Injected so tests can assert what *would* be written without touching the real system index —
/// which is a daemon, is shared across the whole device, and would leave residue behind a test
/// run. Given that the entire point of this type is "never write the wrong thing", tests that
/// could not observe the writes would be worthless.
protocol SpotlightIndexing {
    func indexSearchableItems(_ items: [CSSearchableItem], completionHandler: ((Error?) -> Void)?)
    func deleteSearchableItems(withIdentifiers identifiers: [String], completionHandler: ((Error?) -> Void)?)
    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String], completionHandler: ((Error?) -> Void)?)
}

struct CoreSpotlightIndex: SpotlightIndexing {
    private var index: CSSearchableIndex { .default() }

    func indexSearchableItems(_ items: [CSSearchableItem], completionHandler: ((Error?) -> Void)?) {
        index.indexSearchableItems(items, completionHandler: completionHandler)
    }

    func deleteSearchableItems(withIdentifiers identifiers: [String], completionHandler: ((Error?) -> Void)?) {
        index.deleteSearchableItems(withIdentifiers: identifiers, completionHandler: completionHandler)
    }

    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String], completionHandler: ((Error?) -> Void)?) {
        index.deleteSearchableItems(withDomainIdentifiers: domainIdentifiers, completionHandler: completionHandler)
    }
}
