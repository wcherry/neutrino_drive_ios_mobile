import XCTest
@testable import NeutrinoDrive

final class KeychainServiceTests: XCTestCase {

    // Keys exercised by these tests — distinct from production keys so tests
    // cannot bleed into an AuthService instance running concurrently.
    private let testKey = "nd.test.keychain_service"
    private let testKey2 = "nd.test.keychain_service_alt"

    // MARK: - Lifecycle

    override func tearDown() {
        super.tearDown()
        // Best-effort cleanup; ignore return values.
        _ = KeychainService.delete(forKey: testKey)
        _ = KeychainService.delete(forKey: testKey2)
    }

    // MARK: - Tests

    /// Saving a value and immediately loading it back returns the same string.
    func test_save_thenLoad_returnsSavedValue() {
        let saved = KeychainService.save("secret-value", forKey: testKey)
        XCTAssertTrue(saved, "save(_:forKey:) should return true on success")

        let loaded = KeychainService.load(forKey: testKey)
        XCTAssertEqual(loaded, "secret-value")
    }

    /// Loading a key that was never written returns nil instead of crashing or
    /// returning an empty string.
    func test_load_forMissingKey_returnsNil() {
        let loaded = KeychainService.load(forKey: testKey)
        XCTAssertNil(loaded)
    }

    /// Deleting a key after writing it makes subsequent loads return nil.
    func test_delete_removesValue_loadReturnsNilAfterDelete() {
        _ = KeychainService.save("to-be-deleted", forKey: testKey)

        let deleted = KeychainService.delete(forKey: testKey)
        XCTAssertTrue(deleted, "delete(forKey:) should return true when the item existed")

        let loaded = KeychainService.load(forKey: testKey)
        XCTAssertNil(loaded, "load after delete should return nil")
    }

    /// Saving a value twice for the same key (an update) keeps only the most
    /// recent value — the Keychain item is updated, not duplicated.
    func test_save_twice_secondValueWins() {
        _ = KeychainService.save("first-value", forKey: testKey)
        let secondSave = KeychainService.save("second-value", forKey: testKey)
        XCTAssertTrue(secondSave, "second save (update) should return true")

        let loaded = KeychainService.load(forKey: testKey)
        XCTAssertEqual(loaded, "second-value")
    }

    /// Deleting a key that does not exist must not crash. The return value may
    /// be false (item not found) — both false and true are acceptable as long
    /// as the call completes without throwing or asserting.
    func test_delete_nonExistentKey_doesNotCrash() {
        // Guarantee the key is absent before the call under test.
        _ = KeychainService.delete(forKey: testKey)

        // The only hard requirement is that this line does not crash.
        _ = KeychainService.delete(forKey: testKey)
        // Reaching this point means success.
        XCTAssertTrue(true)
    }

    /// Saving empty string is valid — the Keychain distinguishes "nothing stored"
    /// (nil) from "empty string stored".
    func test_save_emptyString_canBeLoadedBack() {
        let saved = KeychainService.save("", forKey: testKey)
        XCTAssertTrue(saved)

        let loaded = KeychainService.load(forKey: testKey)
        XCTAssertEqual(loaded, "")
    }

    /// Two different keys are independent: writing to one does not affect the
    /// other.
    func test_save_differentKeys_areIndependent() {
        _ = KeychainService.save("value-A", forKey: testKey)
        _ = KeychainService.save("value-B", forKey: testKey2)

        XCTAssertEqual(KeychainService.load(forKey: testKey), "value-A")
        XCTAssertEqual(KeychainService.load(forKey: testKey2), "value-B")
    }
}
