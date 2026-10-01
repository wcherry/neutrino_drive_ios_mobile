import XCTest
import Sodium
@testable import NeutrinoDrive

// MARK: - DeviceKeyCheckTests

final class DeviceKeyCheckTests: XCTestCase {

    private let sodium = Sodium()

    private func b64url(_ bytes: Bytes) -> String {
        sodium.utils.bin2base64(bytes, variant: .URLSAFE_NO_PADDING)!
    }

    func test_status_isCurrent_whenTheStoredKeyIsThePublishedOne() {
        let key = b64url(sodium.box.keyPair()!.publicKey)
        XCTAssertEqual(DeviceKeyCheck.status(storedPublicKey: key,
                                             published: PublishedKey(publicKey: key, version: 2)),
                       .current(version: 2))
    }

    func test_status_isCurrent_whenOnlyThePaddingDiffers() {
        let bytes = sodium.box.keyPair()!.publicKey
        let padded = sodium.utils.bin2base64(bytes, variant: .URLSAFE)!
        XCTAssertEqual(DeviceKeyCheck.status(storedPublicKey: padded,
                                             published: PublishedKey(publicKey: b64url(bytes), version: 1)),
                       .current(version: 1))
    }

    func test_status_isStale_whenTheAccountPublishesAnotherKey() {
        let mine = b64url(sodium.box.keyPair()!.publicKey)
        let published = PublishedKey(publicKey: b64url(sodium.box.keyPair()!.publicKey), version: 1)
        XCTAssertEqual(DeviceKeyCheck.status(storedPublicKey: mine, published: published),
                       .stale(published: published))
    }

    func test_status_isUnpublished_whenTheAccountPublishesNothing() {
        let mine = b64url(sodium.box.keyPair()!.publicKey)
        XCTAssertEqual(DeviceKeyCheck.status(storedPublicKey: mine, published: nil), .unpublished)
    }

    func test_userID_isReadFromTheTokensSubClaim() {
        XCTAssertEqual(DeviceKeyCheck.userID(fromAccessToken: TestJWT.make(sub: "u-42")), "u-42")
        XCTAssertNil(DeviceKeyCheck.userID(fromAccessToken: "not-a-jwt"))
    }
}

// MARK: - DeviceKeyRewrapTests

final class DeviceKeyRewrapTests: XCTestCase {

    private let sodium = Sodium()

    private func b64url(_ bytes: Bytes) -> String {
        sodium.utils.bin2base64(bytes, variant: .URLSAFE_NO_PADDING)!
    }

    /// The incident: a device sealed to its own stale key, filed as v1. After the rewrap the ref
    /// must open with the account's key — the one the web holds — and carry the same DEK.
    func test_rewrap_movesADEKSealedToTheDeviceKeyOntoTheAccountsKey() throws {
        let device = sodium.box.keyPair()!
        let account = sodium.box.keyPair()!
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let sealed = try XCTUnwrap(SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: b64url(device.publicKey)))

        let rewrapped = try XCTUnwrap(DeviceKeyRewrap.rewrap(
            SealedFileKey(sealed: sealed, keyVersion: 1),
            devicePublicKey: b64url(device.publicKey),
            devicePrivateKey: b64url(device.secretKey),
            to: PublishedKey(publicKey: b64url(account.publicKey), version: 4)
        ))

        XCTAssertEqual(rewrapped.keyVersion, 4)
        let opened = SealedKeyCrypto.openDEK(sealedBase64URL: rewrapped.sealed,
                                             publicKeyBase64URL: b64url(account.publicKey),
                                             privateKeyBase64URL: b64url(account.secretKey))
        XCTAssertEqual(opened, dek, "Same DEK, new recipient — the ciphertext is untouched")
    }

    /// A file sealed to the account's key — every file the web or a healthy device uploaded —
    /// does not open with the stale key, and must be left exactly as it is.
    func test_rewrap_leavesARefTheDeviceKeyDoesNotOpenAlone() throws {
        let device = sodium.box.keyPair()!
        let account = sodium.box.keyPair()!
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let sealed = try XCTUnwrap(SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: b64url(account.publicKey)))

        XCTAssertNil(DeviceKeyRewrap.rewrap(
            SealedFileKey(sealed: sealed, keyVersion: 1),
            devicePublicKey: b64url(device.publicKey),
            devicePrivateKey: b64url(device.secretKey),
            to: PublishedKey(publicKey: b64url(account.publicKey), version: 1)
        ))
    }
}
