import XCTest
@testable import NeutrinoDrive

/// Tests for the two-factor branch of sign-in.
///
/// The server answers step 1 for a 2FA account with `{"requiresTwoFactor": true}` and no tokens —
/// the auth fields are flattened and optional. Decoding `accessToken` as required turned that into
/// an unreadable decoding error with no way forward, which is what these pin.
@MainActor
final class AuthServiceTwoFactorTests: XCTestCase {

    private let accessTokenKey = "nd.access_token"

    override func setUp() {
        super.setUp()
        KeychainService.delete(forKey: accessTokenKey)
        MockURLProtocol.reset()
    }

    override func tearDown() {
        KeychainService.delete(forKey: accessTokenKey)
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeSUT(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> AuthService {
        MockURLProtocol.requestHandler = handler
        return AuthService(session: MockURLProtocol.makeSession())
    }

    private func respond(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        return (response, Data(json.utf8))
    }

    // MARK: - Prompting

    func test_login_withTwoFactorAccount_asksForTheCodeInsteadOfFailing() async {
        let sut = makeSUT { self.respond($0, #"{"requiresTwoFactor":true}"#) }

        await sut.login(email: "a@b.c", password: "pw")

        XCTAssertTrue(sut.requiresTwoFactorCode)
        XCTAssertFalse(sut.isAuthenticated)
        // Nothing has gone wrong yet — the server is asking a question, and showing an error
        // beside the field it just revealed reads as though the code was already rejected.
        XCTAssertNil(sut.loginError)
    }

    func test_login_sendsTheCodeOnTheSecondAttempt() async {
        let sut = makeSUT { self.respond($0, #"{"requiresTwoFactor":true}"#) }

        await sut.login(email: "a@b.c", password: "pw")
        await sut.login(email: "a@b.c", password: "pw", totpCode: "123456")

        let body = try! JSONSerialization.jsonObject(
            with: XCTUnwrap(MockURLProtocol.lastRequestBody)
        ) as! [String: Any]
        XCTAssertEqual(body["totpCode"] as? String, "123456")
        XCTAssertEqual(body["email"] as? String, "a@b.c")
    }

    /// An untouched field must not travel as an empty string: the server's `totpCode` is an
    /// `Option<String>`, and "" is a code that was supplied and is wrong.
    func test_login_omitsAnEmptyCode() async {
        let sut = makeSUT { self.respond($0, #"{"requiresTwoFactor":true}"#) }

        await sut.login(email: "a@b.c", password: "pw", totpCode: "")

        let body = try! JSONSerialization.jsonObject(
            with: XCTUnwrap(MockURLProtocol.lastRequestBody)
        ) as! [String: Any]
        XCTAssertNil(body["totpCode"])
    }

    // MARK: - Rejection

    func test_login_withARejectedCode_saysSoAndKeepsTheFieldUp() async {
        var attempts = 0
        let sut = makeSUT { request in
            attempts += 1
            return attempts == 1
                ? self.respond(request, #"{"requiresTwoFactor":true}"#)
                : self.respond(request, #"{"error":"invalid code"}"#, status: 401)
        }

        await sut.login(email: "a@b.c", password: "pw")
        await sut.login(email: "a@b.c", password: "pw", totpCode: "000000")

        XCTAssertTrue(sut.requiresTwoFactorCode, "the field has to stay up to be retried")
        XCTAssertEqual(sut.loginError, AuthError.invalidTwoFactorCode.localizedDescription)
        XCTAssertFalse(sut.isAuthenticated)
    }

    /// A 401 before any code has been asked for is a wrong password, not a wrong code.
    func test_login_withBadCredentials_reportsThemAsCredentials() async {
        let sut = makeSUT { self.respond($0, #"{"error":"unauthorized"}"#, status: 401) }

        await sut.login(email: "a@b.c", password: "wrong")

        XCTAssertFalse(sut.requiresTwoFactorCode)
        XCTAssertEqual(sut.loginError, AuthError.invalidCredentials.localizedDescription)
    }

    // MARK: - Reset

    func test_logout_clearsThePrompt() async {
        let sut = makeSUT { self.respond($0, #"{"requiresTwoFactor":true}"#) }
        await sut.login(email: "a@b.c", password: "pw")
        XCTAssertTrue(sut.requiresTwoFactorCode)

        sut.logout()

        XCTAssertFalse(sut.requiresTwoFactorCode)
    }
}
