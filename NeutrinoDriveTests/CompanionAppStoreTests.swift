import XCTest
import NeutrinoCore
@testable import NeutrinoDrive

/// Tests for the App Store listings offered when a companion app is missing.
///
/// The table is empty today — no product id has been issued to this repository yet — so most of
/// what is worth pinning is the *shape* the entries must take and the invariants that keep an
/// unfilled entry harmless. These are written to become real assertions the moment an id is added,
/// rather than tests that have to be revisited then.
final class CompanionAppStoreTests: XCTestCase {

    // MARK: - URL shape

    /// Whatever ids end up in the table, each must produce a link the App Store app claims.
    func test_url_isAnAppStoreLinkForEveryConfiguredListing() {
        for kind in NeutrinoAppLink.Kind.allCases {
            guard let productID = CompanionAppStore.productID(for: kind) else { continue }
            XCTAssertEqual(CompanionAppStore.url(for: kind)?.absoluteString,
                           "itms-apps://apps.apple.com/app/id\(productID)",
                           "\(kind.appName) has a malformed App Store link")
        }
    }

    /// `itms-apps:` opens the App Store directly; the `https` spelling can bounce through Safari
    /// first, which reads to the user as the link having failed rather than as an install.
    func test_url_usesTheAppStoreScheme() {
        for kind in NeutrinoAppLink.Kind.allCases {
            guard let url = CompanionAppStore.url(for: kind) else { continue }
            XCTAssertEqual(url.scheme, "itms-apps", "\(kind.appName) would open in a browser")
        }
    }

    /// A product id is a numeric App Store item id. A name or a full URL pasted in here would
    /// build a link that resolves to nothing.
    func test_productID_isNumeric() {
        for kind in NeutrinoAppLink.Kind.allCases {
            guard let productID = CompanionAppStore.productID(for: kind) else { continue }
            XCTAssertFalse(productID.isEmpty, "\(kind.appName) has an empty product id")
            XCTAssertTrue(productID.allSatisfy(\.isNumber),
                          "\(kind.appName) product id \u{201C}\(productID)\u{201D} is not an item id")
        }
    }

    // MARK: - Listings

    /// The UI shows its install button on `hasListing`, so the two must never disagree — a true
    /// here with no URL behind it is a button that does nothing when tapped.
    func test_hasListing_agreesWithURL() {
        for kind in NeutrinoAppLink.Kind.allCases {
            XCTAssertEqual(CompanionAppStore.hasListing(for: kind),
                           CompanionAppStore.url(for: kind) != nil,
                           "\(kind.appName) disagrees about whether it can be installed")
        }
    }

    /// Drive is the app doing the asking, and Diagrams and Drawings are web-only. None of the
    /// three can ever be installed from here, whatever gets filled in for the editors.
    func test_noListingForKindsWithoutAnApp() {
        XCTAssertNil(CompanionAppStore.url(for: .file))
        XCTAssertNil(CompanionAppStore.url(for: .diagram))
        XCTAssertNil(CompanionAppStore.url(for: .drawing))
    }

    /// The missing-id case is the one that ships today, and it has to be inert rather than broken:
    /// no URL, no button, and the "Open in Drive" fallback carries the user.
    func test_missingListingYieldsNoURL() {
        for kind in NeutrinoAppLink.Kind.allCases where CompanionAppStore.productID(for: kind) == nil {
            XCTAssertNil(CompanionAppStore.url(for: kind))
            XCTAssertFalse(CompanionAppStore.hasListing(for: kind))
        }
    }
}
