import XCTest
@testable import NeutrinoDrive

/// Tests for handing a file to a sibling Neutrino app.
///
/// `UIApplication.open(_:options:)` is injected, so both branches — companion installed and not —
/// are reachable without a device, which is the only way the "not installed" fallback ever gets
/// exercised in CI.
@MainActor
final class CompanionAppLauncherTests: XCTestCase {

    // MARK: - Helpers

    /// Records the URL it was asked to open and answers with `result`.
    private final class OpenerSpy {
        private(set) var openedURLs: [URL] = []
        var result = true

        func opener() -> CompanionAppLauncher.Opener {
            { @MainActor url in
                self.openedURLs.append(url)
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
}
