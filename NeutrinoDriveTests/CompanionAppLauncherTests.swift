import XCTest
import NeutrinoCore
@testable import NeutrinoDrive

/// Tests for handing a file to a sibling Neutrino app.
///
/// `UIApplication.open(_:options:)` is injected, so both branches — companion installed and not —
/// are reachable without a device, which is the only way the "not installed" fallback ever gets
/// exercised in CI.
@MainActor
final class CompanionAppLauncherTests: XCTestCase {

    // MARK: - Helpers

    /// Records what it was asked to open, and with which option, and answers with `result`.
    private final class OpenerSpy {
        private(set) var openedURLs: [URL] = []
        private(set) var universalLinksOnlyFlags: [Bool] = []
        var result = true

        func opener() -> CompanionAppLauncher.Opener {
            { @MainActor url, universalLinksOnly in
                self.openedURLs.append(url)
                self.universalLinksOnlyFlags.append(universalLinksOnly)
                return self.result
            }
        }
    }

    // MARK: - Success

    func test_open_reportsOpenedWhenCompanionHandlesLink() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        let outcome = await sut.open(NeutrinoAppLink.Destination(kind: .note, fileID: "f1"))

        XCTAssertEqual(outcome, .opened)
    }

    func test_open_passesCanonicalUniversalLink() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        await sut.open(NeutrinoAppLink.Destination(kind: .doc, fileID: "abc"))

        XCTAssertEqual(spy.openedURLs.map(\.absoluteString),
                       ["https://www.getneutrino.app/open/doc/abc"])
    }

    func test_open_forwardsContentVersion() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        await sut.open(NeutrinoAppLink.Destination(kind: .note, fileID: "f1", contentVersion: 9))

        XCTAssertEqual(spy.openedURLs.first?.query, "v=9")
    }

    // MARK: - Not installed

    func test_open_reportsAppNotInstalledWhenNothingHandlesLink() async {
        let spy = OpenerSpy()
        spy.result = false
        let sut = CompanionAppLauncher(opener: spy.opener())

        let outcome = await sut.open(NeutrinoAppLink.Destination(kind: .note, fileID: "f1"))

        XCTAssertEqual(outcome, .appNotInstalled)
    }

    // MARK: - Invalid input

    func test_open_reportsInvalidLinkForEmptyFileID() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        let outcome = await sut.open(NeutrinoAppLink.Destination(kind: .note, fileID: ""))

        XCTAssertEqual(outcome, .invalidLink)
        XCTAssertTrue(spy.openedURLs.isEmpty, "must not ask iOS to open a malformed link")
    }

    // MARK: - MIME entry point

    func test_openByMIME_routesNoteToNotes() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        let outcome = await sut.open(fileID: "f1", mimeType: "application/x-neutrino-note")

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(spy.openedURLs.first?.path, "/open/note/f1")
    }

    func test_openByMIME_refusesUnclaimedType() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        let outcome = await sut.open(fileID: "f1", mimeType: "application/pdf")

        XCTAssertEqual(outcome, .invalidLink)
        XCTAssertTrue(spy.openedURLs.isEmpty)
    }

    // MARK: - OOXML routing

    /// The formats this feature exists for: a `.docx` in Drive is a Neutrino document, so tapping
    /// it must reach Docs rather than fall through to a download.
    func test_openByMIME_routesDocxToDocs() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        let outcome = await sut.open(fileID: "f1", mimeType: NeutrinoAppLink.OOXML.docx)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(spy.openedURLs.first?.path, "/open/doc/f1")
    }

    func test_openByMIME_routesXlsxToSheets() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        await sut.open(fileID: "f1", mimeType: NeutrinoAppLink.OOXML.xlsx)

        XCTAssertEqual(spy.openedURLs.first?.path, "/open/sheet/f1")
    }

    func test_openByMIME_routesPptxToSlides() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        await sut.open(fileID: "f1", mimeType: NeutrinoAppLink.OOXML.pptx)

        XCTAssertEqual(spy.openedURLs.first?.path, "/open/slide/f1")
    }

    // MARK: - Universal links only

    /// The whole fallback rests on this option: without it iOS answers every `https` URL by opening
    /// Safari, the launcher reports `.opened`, and the user lands on a web page instead of the
    /// prompt offering the app.
    func test_open_demandsAUniversalLink() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        await sut.open(NeutrinoAppLink.Destination(kind: .doc, fileID: "f1"))

        XCTAssertEqual(spy.universalLinksOnlyFlags, [true])
    }

    // MARK: - App Store

    func test_openAppStore_doesNothingWithoutAListing() async {
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        // Diagrams are web-only and will never have a listing, so this assertion does not go stale
        // the moment a real product id is filled in for one of the editor apps.
        let opened = await sut.openAppStore(for: .diagram)

        XCTAssertFalse(opened)
        XCTAssertTrue(spy.openedURLs.isEmpty, "must not open a URL it could not build")
    }

    /// Only meaningful once a product id exists. Written as a conditional rather than an
    /// `XCTSkip` so that filling the table in turns this into a real assertion by itself.
    func test_openAppStore_opensTheStoreListingByScheme() async {
        guard let expected = CompanionAppStore.url(for: .doc) else { return }
        let spy = OpenerSpy()
        let sut = CompanionAppLauncher(opener: spy.opener())

        let opened = await sut.openAppStore(for: .doc)

        XCTAssertTrue(opened)
        XCTAssertEqual(spy.openedURLs, [expected])
        // `itms-apps:` is claimed by scheme, not by domain — demanding a universal link would
        // reject it and the install would silently do nothing.
        XCTAssertEqual(spy.universalLinksOnlyFlags, [false])
    }
}
