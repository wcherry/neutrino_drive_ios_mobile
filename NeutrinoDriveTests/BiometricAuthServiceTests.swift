import XCTest
import LocalAuthentication
import NeutrinoAuth
@testable import NeutrinoDrive

// MARK: - FakeBiometricEvaluator

/// Stands in for `LAContext`. There is no way to produce a genuine successful Face ID
/// evaluation in the simulator, and no way to synthesise a lockout, so every interesting
/// behaviour of `BiometricAuthService` is expressed as a decision over this protocol's results
/// and asserted here.
private final class FakeBiometricEvaluator: BiometricEvaluating {

    var biometryType: LABiometryType = .faceID

    /// Result of `canEvaluate`. Default: biometrics are usable.
    var canEvaluateResult: Result<Void, LAError> = .success(())

    /// Queue of results for successive `evaluate` calls. When exhausted, `defaultEvaluateResult`
    /// is used — so a test only has to enumerate the calls it cares about.
    var evaluateResults: [Result<Void, LAError>] = []
    var defaultEvaluateResult: Result<Void, LAError> = .success(())

    private(set) var canEvaluateCallCount = 0
    private(set) var evaluateCallCount = 0
    private(set) var evaluatedPolicies: [LAPolicy] = []
    private(set) var evaluatedReasons: [String] = []

    func canEvaluate(_ policy: LAPolicy) -> Result<Void, LAError> {
        canEvaluateCallCount += 1
        return canEvaluateResult
    }

    func evaluate(_ policy: LAPolicy, reason: String) async -> Result<Void, LAError> {
        evaluateCallCount += 1
        evaluatedPolicies.append(policy)
        evaluatedReasons.append(reason)
        if evaluateResults.isEmpty { return defaultEvaluateResult }
        return evaluateResults.removeFirst()
    }
}

// MARK: - BiometricAuthServiceTests

@MainActor
final class BiometricAuthServiceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var evaluator: FakeBiometricEvaluator!

    override func setUp() {
        super.setUp()
        suiteName = "BiometricAuthServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        evaluator = FakeBiometricEvaluator()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        evaluator = nil
        super.tearDown()
    }

    private func makeSUT(enabled: Bool = false,
                         gracePeriod: TimeInterval = 60,
                         now: Date = Date(timeIntervalSince1970: 1_000_000)) -> BiometricAuthService {
        if enabled { defaults.set(true, forKey: BiometricAuthService.Keys.enabled) }
        defaults.set(gracePeriod, forKey: BiometricAuthService.Keys.gracePeriodSeconds)
        let sut = BiometricAuthService(defaults: defaults, evaluator: evaluator)
        sut.now = { now }
        return sut
    }

    // MARK: - shouldLock (pure decision)

    func test_shouldLock_withNoRecordedBackgrounding_isFalse() {
        XCTAssertFalse(BiometricAuthService.shouldLock(
            lastBackgroundedAt: nil, now: Date(), gracePeriod: 60
        ), "A cold launch is not a re-lock; lockOnLaunch handles that case")
    }

    func test_shouldLock_withinGracePeriod_isFalse() {
        let backgrounded = Date(timeIntervalSince1970: 1_000_000)
        let now = backgrounded.addingTimeInterval(30)
        XCTAssertFalse(BiometricAuthService.shouldLock(
            lastBackgroundedAt: backgrounded, now: now, gracePeriod: 60
        ))
    }

    func test_shouldLock_atExactlyGracePeriod_isTrue() {
        let backgrounded = Date(timeIntervalSince1970: 1_000_000)
        let now = backgrounded.addingTimeInterval(60)
        XCTAssertTrue(BiometricAuthService.shouldLock(
            lastBackgroundedAt: backgrounded, now: now, gracePeriod: 60
        ))
    }

    func test_shouldLock_beyondGracePeriod_isTrue() {
        let backgrounded = Date(timeIntervalSince1970: 1_000_000)
        let now = backgrounded.addingTimeInterval(600)
        XCTAssertTrue(BiometricAuthService.shouldLock(
            lastBackgroundedAt: backgrounded, now: now, gracePeriod: 60
        ))
    }

    func test_shouldLock_withZeroGracePeriod_isTrueImmediately() {
        let backgrounded = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(BiometricAuthService.shouldLock(
            lastBackgroundedAt: backgrounded, now: backgrounded, gracePeriod: 0
        ))
    }

    // MARK: - Error mapping

    func test_errorMapping_userCancel_isCancelled() {
        XCTAssertEqual(BiometricLockError.from(LAError(.userCancel)), .cancelled)
    }

    func test_errorMapping_appCancel_isCancelled() {
        XCTAssertEqual(BiometricLockError.from(LAError(.appCancel)), .cancelled)
    }

    func test_errorMapping_systemCancel_isCancelled() {
        XCTAssertEqual(BiometricLockError.from(LAError(.systemCancel)), .cancelled)
    }

    func test_errorMapping_biometryLockout_isLockedOut() {
        XCTAssertEqual(BiometricLockError.from(LAError(.biometryLockout)), .lockedOut)
    }

    func test_errorMapping_biometryNotEnrolled_isNotEnrolled() {
        XCTAssertEqual(BiometricLockError.from(LAError(.biometryNotEnrolled)), .notEnrolled)
    }

    func test_errorMapping_biometryNotAvailable_isUnavailable() {
        XCTAssertEqual(BiometricLockError.from(LAError(.biometryNotAvailable)), .unavailable)
    }

    func test_errorMapping_passcodeNotSet_isPasscodeNotSet() {
        XCTAssertEqual(BiometricLockError.from(LAError(.passcodeNotSet)), .passcodeNotSet)
    }

    func test_errorMapping_authenticationFailed_isFailed() {
        XCTAssertEqual(BiometricLockError.from(LAError(.authenticationFailed)), .failed)
    }

    func test_lockedOutMessage_pointsAtThePasscode_notAtWaiting() {
        // Telling a locked-out user to "try again later" would strand them; the policy in use
        // genuinely does offer the passcode, and the copy has to say so.
        XCTAssertTrue(BiometricLockError.lockedOut.message.lowercased().contains("passcode"))
    }

    // MARK: - Availability

    func test_availability_whenCanEvaluateSucceeds_isAvailable() {
        evaluator.canEvaluateResult = .success(())
        evaluator.biometryType = .faceID
        let sut = makeSUT()
        XCTAssertEqual(sut.availability(), .available(.faceID))
    }

    func test_availability_whenNotEnrolled_isNotEnrolled() {
        evaluator.canEvaluateResult = .failure(LAError(.biometryNotEnrolled))
        let sut = makeSUT()
        XCTAssertEqual(sut.availability(), .notEnrolled)
    }

    func test_availability_whenPasscodeNotSet_isPasscodeNotSet() {
        evaluator.canEvaluateResult = .failure(LAError(.passcodeNotSet))
        let sut = makeSUT()
        XCTAssertEqual(sut.availability(), .passcodeNotSet)
    }

    func test_availability_whenHardwareMissing_isNotAvailable() {
        evaluator.canEvaluateResult = .failure(LAError(.biometryNotAvailable))
        let sut = makeSUT()
        XCTAssertEqual(sut.availability(), .notAvailable)
    }

    func test_availabilityNotEnrolled_cannotEnable() {
        XCTAssertFalse(BiometricAvailability.notEnrolled.canEnable)
    }

    func test_availabilityAvailable_canEnable() {
        XCTAssertTrue(BiometricAvailability.available(.faceID).canEnable)
    }

    // MARK: - Enable / disable

    func test_enable_whenAvailable_staysOnAndPersists() {
        evaluator.canEvaluateResult = .success(())
        let sut = makeSUT()

        sut.isEnabled = true

        XCTAssertTrue(sut.isEnabled)
        XCTAssertEqual(defaults.object(forKey: BiometricAuthService.Keys.enabled) as? Bool, true)
    }

    func test_enable_whenNotEnrolled_revertsToOffAndReportsWhy() {
        evaluator.canEvaluateResult = .failure(LAError(.biometryNotEnrolled))
        let sut = makeSUT()

        sut.isEnabled = true

        XCTAssertFalse(sut.isEnabled, "The toggle must not claim to be on when biometrics are unusable")
        XCTAssertEqual(sut.lastError, .notEnrolled)
    }

    func test_enable_whenPasscodeNotSet_revertsToOff() {
        evaluator.canEvaluateResult = .failure(LAError(.passcodeNotSet))
        let sut = makeSUT()

        sut.isEnabled = true

        XCTAssertFalse(sut.isEnabled)
        XCTAssertEqual(sut.lastError, .passcodeNotSet)
    }

    func test_enable_whenUnavailable_doesNotPersistEnabledFlag() {
        evaluator.canEvaluateResult = .failure(LAError(.biometryNotAvailable))
        let sut = makeSUT()

        sut.isEnabled = true

        XCTAssertNotEqual(defaults.object(forKey: BiometricAuthService.Keys.enabled) as? Bool, true)
    }

    func test_disable_clearsLockedState() {
        let sut = makeSUT(enabled: true)
        sut.lockOnLaunch()
        XCTAssertTrue(sut.isLocked)

        sut.isEnabled = false

        XCTAssertFalse(sut.isLocked, "Turning the feature off must not leave the user staring at a lock screen")
        XCTAssertNil(sut.lastError)
    }

    // MARK: - Launch

    func test_lockOnLaunch_whenEnabled_locks() {
        let sut = makeSUT(enabled: true)
        sut.lockOnLaunch()
        XCTAssertTrue(sut.isLocked)
    }

    func test_lockOnLaunch_whenDisabled_doesNotLock() {
        let sut = makeSUT(enabled: false)
        sut.lockOnLaunch()
        XCTAssertFalse(sut.isLocked)
    }

    // MARK: - unlock — the "no failure path unlocks" invariant

    func test_unlock_onSuccess_unlocksAndClearsError() async {
        let sut = makeSUT(enabled: true)
        sut.lockOnLaunch()
        evaluator.defaultEvaluateResult = .success(())

        let unlocked = await sut.unlock()

        XCTAssertTrue(unlocked)
        XCTAssertFalse(sut.isLocked)
        XCTAssertNil(sut.lastError)
    }

    func test_unlock_onUserCancel_staysLocked() async {
        let sut = makeSUT(enabled: true)
        sut.lockOnLaunch()
        evaluator.defaultEvaluateResult = .failure(LAError(.userCancel))

        let unlocked = await sut.unlock()

        XCTAssertFalse(unlocked)
        XCTAssertTrue(sut.isLocked, "Cancelling must never be a bypass")
        XCTAssertEqual(sut.lastError, .cancelled)
    }

    func test_unlock_onBiometryLockout_staysLocked() async {
        let sut = makeSUT(enabled: true)
        sut.lockOnLaunch()
        evaluator.defaultEvaluateResult = .failure(LAError(.biometryLockout))

        let unlocked = await sut.unlock()

        XCTAssertFalse(unlocked)
        XCTAssertTrue(sut.isLocked)
        XCTAssertEqual(sut.lastError, .lockedOut)
    }

    func test_unlock_onAuthenticationFailed_staysLocked() async {
        let sut = makeSUT(enabled: true)
        sut.lockOnLaunch()
        evaluator.defaultEvaluateResult = .failure(LAError(.authenticationFailed))

        let unlocked = await sut.unlock()

        XCTAssertFalse(unlocked)
        XCTAssertTrue(sut.isLocked)
        XCTAssertEqual(sut.lastError, .failed)
    }

    func test_unlock_usesDeviceOwnerAuthentication_soPasscodeFallbackIsAlwaysOffered() async {
        let sut = makeSUT(enabled: true)
        sut.lockOnLaunch()

        _ = await sut.unlock()

        XCTAssertEqual(evaluator.evaluatedPolicies, [.deviceOwnerAuthentication],
                       "The biometrics-only policy would strand a locked-out user with no passcode route")
    }

    func test_unlock_onUserFallback_reEvaluatesWithPasscodePolicyAndCanSucceed() async {
        let sut = makeSUT(enabled: true)
        sut.lockOnLaunch()
        evaluator.evaluateResults = [.failure(LAError(.userFallback)), .success(())]

        let unlocked = await sut.unlock()

        XCTAssertTrue(unlocked)
        XCTAssertFalse(sut.isLocked)
        XCTAssertEqual(evaluator.evaluateCallCount, 2)
    }

    func test_unlock_onUserFallbackThenCancel_staysLocked() async {
        let sut = makeSUT(enabled: true)
        sut.lockOnLaunch()
        evaluator.evaluateResults = [.failure(LAError(.userFallback)), .failure(LAError(.userCancel))]

        let unlocked = await sut.unlock()

        XCTAssertFalse(unlocked)
        XCTAssertTrue(sut.isLocked)
    }

    func test_unlock_whenDisabled_isNoOpAndDoesNotPrompt() async {
        let sut = makeSUT(enabled: false)

        let unlocked = await sut.unlock()

        XCTAssertTrue(unlocked)
        XCTAssertFalse(sut.isLocked)
        XCTAssertEqual(evaluator.evaluateCallCount, 0, "A disabled feature must never prompt")
    }

    // MARK: - Scene phase

    func test_sceneDidBecomeInactive_whenEnabled_obscuresContent() {
        let sut = makeSUT(enabled: true)

        sut.sceneDidBecomeInactive()

        XCTAssertTrue(sut.isObscured,
                      "The app-switcher snapshot is taken on .inactive — obscuring only on .background leaks file names")
    }

    func test_sceneDidBecomeInactive_whenDisabled_doesNotObscure() {
        let sut = makeSUT(enabled: false)
        sut.sceneDidBecomeInactive()
        XCTAssertFalse(sut.isObscured)
    }

    func test_shouldPresentOverlay_isTrueWhenObscuredEvenIfUnlocked() {
        let sut = makeSUT(enabled: true)
        sut.sceneDidBecomeInactive()
        XCTAssertFalse(sut.isLocked)
        XCTAssertTrue(sut.shouldPresentOverlay)
    }

    func test_shouldPresentOverlay_isFalseWhenNeitherLockedNorObscured() {
        let sut = makeSUT(enabled: true)
        XCTAssertFalse(sut.shouldPresentOverlay)
    }

    func test_returningToForeground_afterGracePeriodLapsed_locks() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let sut = makeSUT(enabled: true, gracePeriod: 60, now: base)

        sut.sceneDidEnterBackground()
        sut.now = { base.addingTimeInterval(120) }
        sut.sceneDidBecomeActive()

        XCTAssertTrue(sut.isLocked)
        XCTAssertFalse(sut.isObscured)
    }

    func test_returningToForeground_withinGracePeriod_doesNotLock() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let sut = makeSUT(enabled: true, gracePeriod: 60, now: base)

        sut.sceneDidEnterBackground()
        sut.now = { base.addingTimeInterval(10) }
        sut.sceneDidBecomeActive()

        XCTAssertFalse(sut.isLocked)
    }

    func test_returningToForeground_alwaysClearsObscuring() {
        let sut = makeSUT(enabled: true, gracePeriod: 0)
        sut.sceneDidEnterBackground()
        XCTAssertTrue(sut.isObscured)

        sut.sceneDidBecomeActive()

        XCTAssertTrue(sut.isLocked)
        XCTAssertFalse(sut.isObscured, "The overlay stays up via isLocked; isObscured must not linger")
    }

    func test_returningToForeground_whenDisabled_clearsEverything() {
        let sut = makeSUT(enabled: false)
        sut.sceneDidBecomeActive()
        XCTAssertFalse(sut.isLocked)
        XCTAssertFalse(sut.isObscured)
    }

    /// Regression for the infinite Face ID loop: presenting the system prompt itself drops the
    /// scene to `.background` and back while `unlock()` is still in flight. That spurious
    /// backgrounding must not hand `sceneDidBecomeActive()` a fresh timestamp to re-lock against —
    /// otherwise a successful unlock is immediately undone and the lock screen re-prompts forever.
    func test_backgroundingWhileAlreadyLocked_doesNotArmARelockOnTheNextActive() {
        let sut = makeSUT(enabled: true, gracePeriod: 0)
        sut.lockOnLaunch()
        XCTAssertTrue(sut.isLocked)

        // The Face ID sheet's own scene transitions, occurring while still locked/mid-auth.
        sut.sceneDidEnterBackground()
        sut.sceneDidBecomeActive()

        // Nothing to re-lock against: still simply locked, not re-armed into a loop.
        XCTAssertTrue(sut.isLocked)
    }

    /// Once genuinely unlocked, a real backgrounding still re-locks after the grace period — the
    /// fix must not disable re-locking altogether, only the spurious case above.
    func test_genuineBackgroundingAfterUnlock_stillRelocks() async {
        let sut = makeSUT(enabled: true, gracePeriod: 0)
        sut.lockOnLaunch()
        evaluator.defaultEvaluateResult = .success(())
        _ = await sut.unlock()
        XCTAssertFalse(sut.isLocked)

        sut.sceneDidEnterBackground()
        sut.sceneDidBecomeActive()

        XCTAssertTrue(sut.isLocked)
    }

    // MARK: - Key access gate

    func test_authenticateForKeyAccess_whenDisabled_passesWithoutPrompting() async {
        let sut = makeSUT(enabled: false)

        let ok = await sut.authenticateForKeyAccess()

        XCTAssertTrue(ok)
        XCTAssertEqual(evaluator.evaluateCallCount, 0)
    }

    func test_authenticateForKeyAccess_whenEnabled_promptsAndSucceeds() async {
        let sut = makeSUT(enabled: true)
        evaluator.defaultEvaluateResult = .success(())

        let ok = await sut.authenticateForKeyAccess()

        XCTAssertTrue(ok)
        XCTAssertEqual(evaluator.evaluateCallCount, 1)
    }

    func test_authenticateForKeyAccess_whenEnabledAndCancelled_fails() async {
        let sut = makeSUT(enabled: true)
        evaluator.defaultEvaluateResult = .failure(LAError(.userCancel))

        let ok = await sut.authenticateForKeyAccess()

        XCTAssertFalse(ok)
        XCTAssertEqual(sut.lastError, .cancelled)
    }

    func test_authenticateForKeyAccess_shortCircuitsWithinGracePeriodOfLastUnlock() async {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let sut = makeSUT(enabled: true, gracePeriod: 60, now: base)
        sut.lockOnLaunch()
        _ = await sut.unlock()
        let callsAfterUnlock = evaluator.evaluateCallCount

        sut.now = { base.addingTimeInterval(5) }
        let ok = await sut.authenticateForKeyAccess()

        XCTAssertTrue(ok)
        XCTAssertEqual(evaluator.evaluateCallCount, callsAfterUnlock,
                       "Re-prompting someone who unlocked five seconds ago is friction with no security value")
    }

    func test_authenticateForKeyAccess_promptsAgainOnceGracePeriodHasLapsed() async {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let sut = makeSUT(enabled: true, gracePeriod: 60, now: base)
        sut.lockOnLaunch()
        _ = await sut.unlock()
        let callsAfterUnlock = evaluator.evaluateCallCount

        sut.now = { base.addingTimeInterval(600) }
        _ = await sut.authenticateForKeyAccess()

        XCTAssertEqual(evaluator.evaluateCallCount, callsAfterUnlock + 1)
    }

    // MARK: - Grace period persistence

    func test_gracePeriod_defaultsToOneMinute() {
        let sut = BiometricAuthService(defaults: defaults, evaluator: evaluator)
        XCTAssertEqual(sut.gracePeriod, BiometricAuthService.defaultGracePeriod)
        XCTAssertEqual(BiometricAuthService.defaultGracePeriod, 60)
    }

    func test_gracePeriod_persistsAcrossInstances() {
        let sut = makeSUT()
        sut.gracePeriod = 300

        let reloaded = BiometricAuthService(defaults: defaults, evaluator: evaluator)

        XCTAssertEqual(reloaded.gracePeriod, 300)
    }

    func test_gracePeriodOptions_includeImmediate() {
        XCTAssertTrue(BiometricAuthService.gracePeriodOptions.contains(0))
    }
}
