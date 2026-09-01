import Foundation

/// A stand-in access token carrying a `sub` claim.
///
/// Tests that exercise a Drive listing need one: the drive root is addressed as
/// `/api/v1/drive/folders/{user id}`, and `AccessToken` reads that id out of the stored token. An
/// opaque placeholder string is not enough any more, and a test that used one browsed as though
/// signed out.
///
/// Unsigned in any meaningful sense — nothing on the client verifies a token, and the server
/// checks the signature on every request it actually serves.
enum TestJWT {
    static func make(sub: String = "test-user") -> String {
        let payload = try! JSONSerialization.data(
            withJSONObject: ["sub": sub, "email": "\(sub)@example.com"]
        )
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
