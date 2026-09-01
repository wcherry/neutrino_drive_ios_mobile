import Foundation

// MARK: - AccessToken

/// Reads the claims the client needs out of the stored access token.
///
/// Deliberately not a verification of anything: the server checks the signature on every request,
/// and nothing here decides whether a caller is allowed to do something. It only saves a round trip
/// for facts the server has already signed and handed over.
enum AccessToken {

    /// The signed-in user's id, from the token's `sub` claim.
    ///
    /// A user's root folder id *is* their user id (`GET /api/v1/drive/folders/{id}`), which is how
    /// the Drive listing addresses the root without a call to `/api/v1/auth/me` first.
    static func currentUserID() -> String? {
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count > 1 else { return nil }

        // A JWT payload is base64url without padding; `Data(base64Encoded:)` wants standard
        // base64 with it.
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }

        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: data) else { return nil }
        return claims.sub
    }

    /// The subset of a JWT's claims this reads.
    private struct Claims: Decodable {
        let sub: String
    }
}
