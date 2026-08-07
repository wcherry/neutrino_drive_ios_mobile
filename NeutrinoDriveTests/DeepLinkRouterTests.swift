import XCTest
@testable import NeutrinoDrive

/// Tests for the inbound half of Universal Links: what Drive accepts, and how long it holds on to
/// a link that arrives before the app can act on it.
@MainActor
final class DeepLinkRouterTests: XCTestCase {

    // MARK: - Accepting

    func test_handle_acceptsFileLink() {
        let sut = DeepLinkRouter()

        let accepted = sut.handle(URL(string: "https://www.getneutrino.app/open/file/f1")!)

        XCTAssertTrue(accepted)
        XCTAssertEqual(sut.pending?.fileID, "f1")
    }

    /// Drive is the last resort for a link whose own app is not installed, so it accepts every
    /// kind rather than only `.file`.
    func test_handle_acceptsNoteLink() {
        let sut = DeepLinkRouter()

        XCTAssertTrue(sut.handle(URL(string: "https://www.getneutrino.app/open/note/f1")!))
        XCTAssertEqual(sut.pending?.kind, .note)
    }

    func test_handle_carriesContentVersion() {
        let sut = DeepLinkRouter()

        sut.handle(URL(string: "https://www.getneutrino.app/open/file/f1?v=12")!)

        XCTAssertEqual(sut.pending?.contentVersion, 12)
    }

    // MARK: - Rejecting

    /// The key-file "Open In" flow shares `onOpenURL`, so a `file://` URL has to fall through
    /// untouched rather than being swallowed here.
    func test_handle_rejectsFileURLSoKeyImportStillSeesIt() {
        let sut = DeepLinkRouter()

        let accepted = sut.handle(URL(fileURLWithPath: "/tmp/neutrino-key.json"))

        XCTAssertFalse(accepted)
        XCTAssertNil(sut.pending)
    }

    func test_handle_rejectsForeignHost() {
        let sut = DeepLinkRouter()

        XCTAssertFalse(sut.handle(URL(string: "https://evil.example.com/open/file/f1")!))
        XCTAssertNil(sut.pending)
    }

    func test_handle_rejectsOrdinaryWebsiteURL() {
        let sut = DeepLinkRouter()

        XCTAssertFalse(sut.handle(URL(string: "https://www.getneutrino.app/pricing")!))
        XCTAssertNil(sut.pending)
    }

    // MARK: - Consuming

    func test_consume_returnsAndClearsPending() {
        let sut = DeepLinkRouter(pending: .init(kind: .file, fileID: "f1"))

        XCTAssertEqual(sut.consume()?.fileID, "f1")
        XCTAssertNil(sut.pending)
    }

    /// Guards the double-present bug: SwiftUI re-evaluates a view tree freely, and a destination
    /// that survived consumption would open the same sheet again.
    func test_consume_isIdempotent() {
        let sut = DeepLinkRouter(pending: .init(kind: .file, fileID: "f1"))

        _ = sut.consume()

        XCTAssertNil(sut.consume())
    }

    func test_handle_replacesAnEarlierUnconsumedLink() {
        let sut = DeepLinkRouter()

        sut.handle(URL(string: "https://www.getneutrino.app/open/file/first")!)
        sut.handle(URL(string: "https://www.getneutrino.app/open/file/second")!)

        XCTAssertEqual(sut.pending?.fileID, "second")
    }

    /// A link that arrives at the login screen has to survive until there is a session to open it
    /// with — nothing but `consume()` may clear it.
    func test_pending_survivesUntilConsumed() {
        let sut = DeepLinkRouter()

        sut.handle(URL(string: "https://www.getneutrino.app/open/file/f1")!)

        XCTAssertNotNil(sut.pending)
        XCTAssertNotNil(sut.pending)
    }

    func test_clear_dropsPending() {
        let sut = DeepLinkRouter(pending: .init(kind: .file, fileID: "f1"))

        sut.clear()

        XCTAssertNil(sut.pending)
    }
}
