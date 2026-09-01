import XCTest
import CryptoKit
@testable import NeutrinoDrive

/// Tests for `RecoveryKit`.
///
/// As with the key code, the thing worth proving is agreement with the *other* implementation:
/// a kit is printed by `web/packages/e2e-crypto/src/recoveryKit.ts` and typed in here, so the
/// leading test runs against a kit that module actually produced, with the keyring it encoded
/// captured alongside it.
final class RecoveryKitTests: XCTestCase {

    // MARK: - Cross-implementation vector

    /// A three-version keyring — v1 and v2 retired, v3 active — exported by `exportRecoveryKit`.
    private static let webKit = """
    9R0G-6001-1N5Y-9N7G-TS1T-MBGR-ZHB6-Q0H7
    8P3P-Z49P-S31E-XGS0-DR26-0DDG-4X60-2002
    XRT7-1J6M-XD90-KZPZ-2EQJ-4Z08-XWJ5-1W57
    7A06-D6E0-EC8R-N8T2-0E30-2003-4RPN-8XV4
    GKCH-20T9-9M66-4WB7-W2VE-AZQ9-JHEF-FKYS
    1160-CTTT-TRE0-0
    """

    /// The entries that kit encodes, as base64url, straight from the same keyring object.
    private static let webEntries: [(version: Int, retired: Bool, pk: String, sk: String)] = [
        (1, true,  "uVDyFcDTBTsf1a8j0o6ggJj2NVKRSBG8D_SkRxAQGVU", "DUvk1PDWQ6ouGPxWa4InRYdvkTbIwu7DIG4EYDWwJ0w"),
        (2, true,  "6S71Q-OYVNTDzLEs9Hf6rVT0Zn6lraox3ncK6noNLFQ", "7jRwyNTrUgn-3xOvInwI7yRQ8Kc6gGaZwHMRiqNCA4Y"),
        (3, false, "sKVUuq7A9s6zuQmwc2BhKEY-1O_Mj1zm4H6iTjWfuSs", "Ji1Ud2SE2REDSU0MYnFn4LblfumUXPfP2QhMBmta1hw"),
    ]

    func test_importKit_readsAKitPrintedByTheWebClient() throws {
        let contents = try RecoveryKit.importKit(Self.webKit)

        XCTAssertEqual(contents.activeVersion, 3)
        XCTAssertEqual(contents.keys.map(\.version), [1, 2, 3])
        XCTAssertEqual(contents.retired.map(\.version), [1, 2])

        for expected in Self.webEntries {
            let key = try XCTUnwrap(contents.keys.first { $0.version == expected.version })
            XCTAssertEqual(key.privateKey, expected.sk, "secret key for v\(expected.version)")
            // Derived here rather than carried in the frame — this is what proves the derivation
            // matches the one the web used when it sealed files to these versions.
            XCTAssertEqual(key.publicKey, expected.pk, "public key for v\(expected.version)")
        }
    }

    /// The kit is copied by hand, so the forms someone actually writes have to work.
    func test_importKit_toleratesHowTheKitIsActuallyTranscribed() throws {
        let canonical = try RecoveryKit.importKit(Self.webKit)

        let lowercased = try RecoveryKit.importKit(Self.webKit.lowercased())
        XCTAssertEqual(lowercased, canonical)

        let unspaced = try RecoveryKit.importKit(
            Self.webKit.replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "\n", with: " ")
        )
        XCTAssertEqual(unspaced, canonical)

        // Crockford's ambiguous characters, written the way a person reads them off paper.
        let misread = try RecoveryKit.importKit(
            Self.webKit.replacingOccurrences(of: "0", with: "O")
                .replacingOccurrences(of: "1", with: "l")
        )
        XCTAssertEqual(misread, canonical)
    }

    // MARK: - Refusals

    func test_importKit_rejectsSomethingThatIsNotAKit() {
        for text in ["", "hello there", "234567234567234567234567234567234567234567234567234567234567234567"] {
            XCTAssertThrowsError(try RecoveryKit.importKit(text), "for \(text)")
        }
    }

    /// A truncated kit is the likely outcome of copying by hand. It must not produce a short read
    /// that installs a subtly wrong key.
    func test_importKit_rejectsATruncatedKit() {
        let truncated = String(RecoveryKit.normalize(Self.webKit).dropLast(40))

        XCTAssertThrowsError(try RecoveryKit.importKit(truncated)) { error in
            guard case RecoveryKitError.incomplete = error else {
                return XCTFail("Expected incomplete, got \(error)")
            }
        }
    }

    func test_looksLikeKit_separatesAKitFromAKeyFile() {
        XCTAssertTrue(RecoveryKit.looksLikeKit(Self.webKit))
        XCTAssertFalse(RecoveryKit.looksLikeKit("{\"public_key\":\"abc\"}"))
        XCTAssertFalse(RecoveryKit.looksLikeKit("9R0G-6001"))
    }

    // MARK: - Install

    /// The kit's active entry has to land where every read path already looks, and the rest in the
    /// archive `SealedKeyCrypto` falls back to — otherwise a restored device opens only the files
    /// written since the last rotation, which is the failure the kit exists to prevent.
    func test_install_splitsTheKitIntoTheActiveKeyAndTheArchive() throws {
        let contents = try RecoveryKit.importKit(Self.webKit)
        defer { KeyImportService.removeKeys() }

        XCTAssertTrue(RecoveryKit.install(contents))

        XCTAssertEqual(SealedKeyCrypto.activeKeyVersion(), 3)
        guard case .found(let publicKey, let privateKey) = SealedKeyCrypto.storedKeyPair(forVersion: 3) else {
            return XCTFail("v3 should resolve to the active key")
        }
        XCTAssertEqual(publicKey, Self.webEntries[2].pk)
        XCTAssertEqual(privateKey, Self.webEntries[2].sk)

        for expected in Self.webEntries.dropLast() {
            guard case .found(let pk, let sk) = SealedKeyCrypto.storedKeyPair(forVersion: expected.version) else {
                return XCTFail("v\(expected.version) should resolve out of the archive")
            }
            XCTAssertEqual(pk, expected.pk)
            XCTAssertEqual(sk, expected.sk)
        }
    }

    /// A DEK sealed to a retired version — the case that motivates carrying the whole keyring —
    /// must open after a restore.
    func test_install_leavesRetiredVersionsAbleToOpenTheirFiles() throws {
        let contents = try RecoveryKit.importKit(Self.webKit)
        defer { KeyImportService.removeKeys() }
        XCTAssertTrue(RecoveryKit.install(contents))

        let dek: [UInt8] = Array(repeating: 7, count: 32)
        let sealed = try XCTUnwrap(
            SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: Self.webEntries[0].pk)
        )

        XCTAssertEqual(SealedKeyCrypto.openDEKWithStoredKeys(sealedBase64URL: sealed, keyVersion: 1),
                       dek)
    }
}
