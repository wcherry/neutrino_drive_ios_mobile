import XCTest
import Sodium
import NeutrinoCrypto
@testable import NeutrinoDrive

// MARK: - KeyFileServiceTests
//
// The key file is what lets this device read files uploaded before the account's
// last rotation. It arrives as ciphertext the server cannot open, so the only
// place the entries are checked is here — which makes "what does this accept,
// and what does it refuse" the whole of the security story for this path.
//
// `plan` is tested rather than `restoreArchivedKeys`, because everything the
// latter adds is one authenticated GET; the decisions are all in `plan`, and
// they are exercised here against real sealed boxes rather than fixtures.

@MainActor
final class KeyFileServiceTests: XCTestCase {

    private let sodium = Sodium()

    override func tearDown() {
        KeyImportService.removeKeys()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// One entry as the web app's `buildKeyFile` writes it: a retired secret key sealed to the
    /// active public key, with its own public half declared alongside.
    private func archived(version: Int,
                          pair: Box.KeyPair,
                          sealedTo active: Box.KeyPair,
                          declarePublicKey: Bool = true) -> ArchivedKeyDTO {
        ArchivedKeyDTO(
            keyVersion: version,
            encryptedKey: b64(sodium.box.seal(message: pair.secretKey,
                                              recipientPublicKey: active.publicKey)!),
            publicKey: declarePublicKey ? b64(pair.publicKey) : nil
        )
    }

    private func b64(_ bytes: Bytes) -> String {
        SealedKeyCrypto.encodeBase64URL(bytes)!
    }

    private func plan(_ keys: [ArchivedKeyDTO],
                      active: Box.KeyPair,
                      activeVersion: Int,
                      held: Set<Int> = []) -> (outcome: KeyFileRestoreOutcome, keys: [StoredKeyPair]) {
        KeyFileService.plan(keys: keys,
                            activePublicKey: active.publicKey,
                            activeSecretKey: active.secretKey,
                            activeVersion: activeVersion,
                            held: held)
    }

    private func storeActive(_ pair: Box.KeyPair, version: Int) {
        KeyImportService.storeKeys(KeyBundle(publicKey: b64(pair.publicKey),
                                             privateKey: b64(pair.secretKey),
                                             keyVersion: String(version)))
    }

    // MARK: - The case this exists for

    /// A device that scanned the key code holds v3 and nothing else. Everything uploaded before the
    /// last rotation is sealed to v1 and v2, and this is the only thing that brings them across.
    func testRecoversTheRetiredKeysAnEnrolledDeviceNeverReceived() {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let v3 = sodium.box.keyPair()!

        let result = plan([archived(version: 1, pair: v1, sealedTo: v3),
                           archived(version: 2, pair: v2, sealedTo: v3)],
                          active: v3, activeVersion: 3)

        XCTAssertEqual(result.outcome.recovered, 2)
        XCTAssertEqual(result.outcome.unopenable, 0)
        XCTAssertFalse(result.outcome.activeIsStale)

        XCTAssertEqual(result.keys.map(\.version), [1, 2])
        XCTAssertEqual(result.keys[0].privateKey, b64(v1.secretKey))
        XCTAssertEqual(result.keys[1].privateKey, b64(v2.secretKey))
    }

    /// The end of the story: a recovered key opens a DEK sealed to the version it belongs to,
    /// which is the whole reason for pulling the file at all.
    func testARecoveredKeyOpensADEKSealedToItsVersion() {
        let old = sodium.box.keyPair()!
        let active = sodium.box.keyPair()!

        // A file from before the rotation: its DEK is sealed to the old public key.
        let dek = sodium.randomBytes.buf(length: 32)!
        let sealedDEK = SealedKeyCrypto.seal(dek: dek, toPublicKeyBase64URL: b64(old.publicKey))!

        // This device holds only the active key, so v1 is not resolvable yet.
        storeActive(active, version: 2)
        XCTAssertEqual(SealedKeyCrypto.storedKeyPair(forVersion: 1), .missingVersion(1))
        XCTAssertNil(SealedKeyCrypto.openDEKWithStoredKeys(sealedBase64URL: sealedDEK, keyVersion: 1))

        // Pull the key file, store what it yields, and the same file opens.
        let result = plan([archived(version: 1, pair: old, sealedTo: active)],
                          active: active, activeVersion: 2)
        XCTAssertTrue(KeyArchive.store(result.keys))

        XCTAssertEqual(SealedKeyCrypto.openDEKWithStoredKeys(sealedBase64URL: sealedDEK, keyVersion: 1),
                       dek)
    }

    // MARK: - Repeat pulls

    /// The launch-time top-up runs on every start. A device that already holds everything reports
    /// it as already held rather than counting it as newly recovered.
    func testAKeyAlreadyHeldIsReportedRatherThanRecovered() {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!

        let result = plan([archived(version: 1, pair: v1, sealedTo: v2)],
                          active: v2, activeVersion: 2, held: [1])

        XCTAssertEqual(result.outcome.alreadyHeld, 1)
        XCTAssertEqual(result.outcome.recovered, 0)
        // Still returned: the archive is replaced wholesale, so dropping it here would delete a key
        // this device is meant to keep.
        XCTAssertEqual(result.keys.map(\.version), [1])
    }

    /// The active key is already in the Keychain, and the archive is stored as a replacement — so
    /// an entry for the active version must not be duplicated into it.
    func testTheActiveVersionIsNotArchived() {
        let v2 = sodium.box.keyPair()!

        let result = plan([archived(version: 2, pair: v2, sealedTo: v2)],
                          active: v2, activeVersion: 2)

        XCTAssertTrue(result.keys.isEmpty)
        XCTAssertEqual(result.outcome.recovered, 0)
    }

    // MARK: - Staleness

    /// The file holds retired keys only, so a version in it that this device believes is current
    /// means the account rotated since this key was issued — and the newest version is not in the
    /// file either, because only retired ones are.
    func testAnActiveVersionAppearingInTheFileIsReportedAsStale() {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let v3 = sodium.box.keyPair()!

        let result = plan([archived(version: 1, pair: v1, sealedTo: v3),
                           archived(version: 2, pair: v2, sealedTo: v3)],
                          active: v2, activeVersion: 2)

        XCTAssertTrue(result.outcome.activeIsStale)
    }

    func testAFileSealedToANewerKeyOpensNothing() {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let v3 = sodium.box.keyPair()!

        let result = plan([archived(version: 1, pair: v1, sealedTo: v3)],
                          active: v2, activeVersion: 2)

        XCTAssertEqual(result.outcome.unopenable, 1)
        XCTAssertTrue(result.keys.isEmpty)
    }


    /// A half-readable file must not delete keys that arrived by another route.
    ///
    /// This is a device whose active key the account has rotated away from: nothing in the file
    /// opens, and the retired keys it already holds — from a recovery kit, or an earlier pull —
    /// are the only reason its older files still open at all. `plan` reports the entries as
    /// unopenable and returns none of them, which is what the caller keys the merge off.
    func testAHalfReadableFileYieldsNothingToReplaceTheArchiveWith() {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let v3 = sodium.box.keyPair()!

        // Holding v2 and already archiving v1; the file is sealed to v3, which this device lacks.
        let result = plan([archived(version: 1, pair: v1, sealedTo: v3)],
                          active: v2, activeVersion: 2, held: [1])

        XCTAssertEqual(result.outcome.unopenable, 1)
        XCTAssertTrue(result.keys.isEmpty,
                      "nothing opened, so the caller has to merge rather than replace")
    }

    // MARK: - What is refused

    /// The declared public half is checked against the one derived from the secret, never trusted
    /// in its place. A mismatch means the entry is not what it claims, and installing it would
    /// surface later as files that will not open.
    func testAnEntryWhoseDeclaredPublicKeyDoesNotMatchIsRefused() {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        let imposter = sodium.box.keyPair()!

        let entry = archived(version: 1, pair: v1, sealedTo: v2)
        let tampered = ArchivedKeyDTO(keyVersion: entry.keyVersion,
                                      encryptedKey: entry.encryptedKey,
                                      publicKey: b64(imposter.publicKey))

        let result = plan([tampered], active: v2, activeVersion: 2)

        XCTAssertEqual(result.outcome.unopenable, 1)
        XCTAssertTrue(result.keys.isEmpty)
    }

    /// A sealed secret of the wrong length is a damaged entry, not a key. It is dropped rather than
    /// stored, since a 16-byte "secret key" clamps into a valid-looking scalar that opens nothing.
    func testAnEntryCarryingTheWrongNumberOfBytesIsRefused() {
        let v2 = sodium.box.keyPair()!
        let truncated = sodium.box.seal(message: Array(sodium.randomBytes.buf(length: 16)!),
                                        recipientPublicKey: v2.publicKey)!

        let result = plan([ArchivedKeyDTO(keyVersion: 1,
                                          encryptedKey: b64(truncated),
                                          publicKey: nil)],
                          active: v2, activeVersion: 2)

        XCTAssertEqual(result.outcome.unopenable, 1)
        XCTAssertTrue(result.keys.isEmpty)
    }

    /// The public half is optional on the wire. Without it the entry is still accepted — the half
    /// is derived from the secret either way — so an older writer's file is not turned away.
    func testAnEntryWithNoDeclaredPublicKeyIsStillAccepted() {
        let v1 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!

        let result = plan([archived(version: 1, pair: v1, sealedTo: v2, declarePublicKey: false)],
                          active: v2, activeVersion: 2)

        XCTAssertEqual(result.outcome.recovered, 1)
        XCTAssertEqual(result.keys[0].publicKey, b64(v1.publicKey))
    }

    // MARK: - Wire format

    /// The response is decoded with a plain `JSONDecoder`, so the field names have to match the
    /// server's camelCase exactly. A snake-case-converting decoder here would silently fail.
    func testDecodesTheServersResponseShape() throws {
        let json = """
        {"userId":"u1",
         "keys":[{"keyVersion":2,"encryptedKey":"AAAA","publicKey":"BBBB"}],
         "createdAt":"2026-08-01T00:00:00Z",
         "updatedAt":"2026-08-22T00:00:00Z"}
        """
        let decoded = try JSONDecoder().decode(KeyFileResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.userId, "u1")
        XCTAssertEqual(decoded.keys.count, 1)
        XCTAssertEqual(decoded.keys[0].keyVersion, 2)
        XCTAssertEqual(decoded.keys[0].encryptedKey, "AAAA")
        XCTAssertEqual(decoded.keys[0].publicKey, "BBBB")
    }
}

// MARK: - KeyArchiveTests

/// The archive is where the recovered keys live between launches. Its one job is to hand back
/// exactly what was put in, under the version it was filed at.
final class KeyArchiveTests: XCTestCase {

    override func tearDown() {
        KeyImportService.removeKeys()
        super.tearDown()
    }

    private func pair(_ version: Int) -> StoredKeyPair {
        let kp = Sodium().box.keyPair()!
        return StoredKeyPair(version: version,
                             publicKey: SealedKeyCrypto.encodeBase64URL(kp.publicKey)!,
                             privateKey: SealedKeyCrypto.encodeBase64URL(kp.secretKey)!)
    }

    func testRoundTripsThroughTheKeychain() {
        let keys = [pair(1), pair(2)]
        XCTAssertTrue(KeyArchive.store(keys))

        XCTAssertEqual(KeyArchive.load(), keys)
        XCTAssertEqual(KeyArchive.keyPair(forVersion: 2), keys[1])
        XCTAssertNil(KeyArchive.keyPair(forVersion: 3))
    }

    func testStoringReplacesRatherThanMerges() {
        XCTAssertTrue(KeyArchive.store([pair(1), pair(2)]))
        let replacement = [pair(1)]
        XCTAssertTrue(KeyArchive.store(replacement))

        XCTAssertEqual(KeyArchive.load(), replacement,
                       "a key dropped from the account's key file has to disappear here too")
    }

    /// Two entries for one version means one of them is wrong and there is no way to tell which.
    /// The first wins, deterministically, rather than the set carrying both.
    func testDuplicateVersionsAreCollapsed() {
        let first = pair(1)
        XCTAssertTrue(KeyArchive.store([first, pair(1)]))

        XCTAssertEqual(KeyArchive.load(), [first])
    }

    func testStoringNothingClearsTheArchive() {
        XCTAssertTrue(KeyArchive.store([pair(1)]))
        XCTAssertTrue(KeyArchive.store([]))

        XCTAssertTrue(KeyArchive.load().isEmpty)
    }

    /// Forgetting the identity has to forget all of it — the retired keys open the same files as
    /// the active one.
    func testRemovingTheIdentityClearsTheArchiveToo() {
        XCTAssertTrue(KeyArchive.store([pair(1)]))

        KeyImportService.removeKeys()

        XCTAssertTrue(KeyArchive.load().isEmpty)
    }

    /// The share extension compiles `KeyArchive` and reads it from the shared access group, so an
    /// upload it triggers resolves versions the same way the app does.
    func testTheArchiveLivesBesideTheActiveKey() {
        XCTAssertEqual(KeyArchive.keychainKey, SharedStorage.Keys.archivedKeys)
        XCTAssertEqual(SharedStorage.Keys.archivedKeys, "nd.encryption.archived_keys")
    }
}

// MARK: - KeyVersionResolutionTests

/// Which key a given file's `keyVersion` resolves to. The three outcomes are distinct on purpose:
/// they send the user to different places.
final class KeyVersionResolutionTests: XCTestCase {

    override func tearDown() {
        KeyImportService.removeKeys()
        super.tearDown()
    }

    @discardableResult
    private func storeActive(version: Int) -> Box.KeyPair {
        let kp = Sodium().box.keyPair()!
        KeyImportService.storeKeys(KeyBundle(
            publicKey: SealedKeyCrypto.encodeBase64URL(kp.publicKey)!,
            privateKey: SealedKeyCrypto.encodeBase64URL(kp.secretKey)!,
            keyVersion: String(version)))
        return kp
    }

    func testTheActiveVersionResolvesToTheKeychainPair() {
        let kp = storeActive(version: 3)

        XCTAssertEqual(SealedKeyCrypto.storedKeyPair(forVersion: 3),
                       .found(publicKey: SealedKeyCrypto.encodeBase64URL(kp.publicKey)!,
                              privateKey: SealedKeyCrypto.encodeBase64URL(kp.secretKey)!))
    }

    func testARetiredVersionResolvesToTheArchive() {
        storeActive(version: 3)
        XCTAssertTrue(KeyArchive.store([StoredKeyPair(version: 1,
                                                      publicKey: "pub-1",
                                                      privateKey: "priv-1")]))

        XCTAssertEqual(SealedKeyCrypto.storedKeyPair(forVersion: 1),
                       .found(publicKey: "pub-1", privateKey: "priv-1"))
    }

    /// The distinction that matters: a version nobody holds is named, so the app can say which key
    /// is missing rather than reporting an unexplained decrypt failure.
    func testAVersionInNeitherPlaceIsNamed() {
        storeActive(version: 3)

        XCTAssertEqual(SealedKeyCrypto.storedKeyPair(forVersion: 2), .missingVersion(2))
    }

    func testNoKeyAtAllIsDistinctFromAMissingVersion() {
        KeyImportService.removeKeys()

        XCTAssertEqual(SealedKeyCrypto.storedKeyPair(forVersion: 1), .noKey)
    }

    /// A key stored before the version field meant anything reads as 1 — which is what the server
    /// defaults `file_key_refs.key_version` to for the rows written at the same time.
    func testAnUnparseableStoredVersionReadsAsOne() {
        KeyImportService.storeKeys(KeyBundle(publicKey: "pub", privateKey: "priv", keyVersion: ""))

        XCTAssertEqual(SealedKeyCrypto.activeKeyVersion(), 1)
        XCTAssertEqual(SealedKeyCrypto.storedKeyPair(forVersion: 1),
                       .found(publicKey: "pub", privateKey: "priv"))
    }
}
