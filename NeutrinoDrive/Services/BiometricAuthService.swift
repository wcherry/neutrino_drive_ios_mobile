import Foundation
import LocalAuthentication
import os.log

// MARK: - BiometricEvaluating

/// Abstraction over `LAContext` so the lock state machine can be unit-tested.
///
/// `LAContext` cannot be driven from a test: there is no simulator API that produces a genuine
/// successful Face ID evaluation, and no way to synthesise a lockout. Everything interesting
/// about this feature is therefore expressed as decisions over this protocol's results, and the
/// tests inject a fake that returns canned `LAError`s.
protocol BiometricEvaluating: AnyObject {
    var biometryType: LABiometryType { get }
    func canEvaluate(_ policy: LAPolicy) -> Result<Void, LAError>
    func evaluate(_ policy: LAPolicy, reason: String) async -> Result<Void, LAError>
}

// MARK: - LAContextEvaluator

/// Production `BiometricEvaluating`.
///
/// A **fresh `LAContext` per evaluation** is deliberate. `LAContext` caches a successful
/// evaluation for the lifetime of the instance (`touchIDAuthenticationAllowableReuseDuration`
/// defaults aside, the result itself is sticky), so reusing one across lock cycles produces the
/// classic "it let me straight back in without asking" bug — which for a security gate is a
/// silent bypass, not a cosmetic glitch.
final class LAContextEvaluator: BiometricEvaluating {

    var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    func canEvaluate(_ policy: LAPolicy) -> Result<Void, LAError> {
        let context = LAContext()
        var nsError: NSError?
        if context.canEvaluatePolicy(policy, error: &nsError) {
            return .success(())
        }
        if let nsError, let code = LAError.Code(rawValue: nsError.code) {
            return .failure(LAError(code))
        }
        return .failure(LAError(.biometryNotAvailable))
    }

    func evaluate(_ policy: LAPolicy, reason: String) async -> Result<Void, LAError> {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
            return ok ? .success(()) : .failure(LAError(.authenticationFailed))
        } catch let error as LAError {
            return .failure(error)
        } catch {
            return .failure(LAError(.authenticationFailed))
        }
    }
}

// MARK: - BiometricAvailability

enum BiometricAvailability: Equatable {
    case available(LABiometryType)
    case notEnrolled
    case notAvailable
    case passcodeNotSet

    /// Whether the Settings toggle may be switched on.
    var canEnable: Bool {
        if case .available = self { return true }
        return false
    }

    var explanation: String {
        switch self {
        case .available(.faceID):  return "Face ID is available on this device."
        case .available(.touchID): return "Touch ID is available on this device."
        case .available:           return "Biometric authentication is available on this device."
        case .notEnrolled:         return "Face ID or Touch ID is not set up. Enrol in iOS Settings to use this."
        case .passcodeNotSet:      return "Set a device passcode in iOS Settings to use this."
        case .notAvailable:        return "This device does not support Face ID or Touch ID."
        }
    }
}

// MARK: - BiometricLockError

enum BiometricLockError: Error, Equatable {
    case cancelled
    case failed
    case lockedOut
    case unavailable
    case notEnrolled
    case passcodeNotSet

    /// Copy shown on the lock screen. Never phrased as "try again later" for `lockedOut` —
    /// `.deviceOwnerAuthentication` genuinely does offer the passcode, and telling a locked-out
    /// user to wait would strand them.
    var message: String {
        switch self {
        case .cancelled:      return "Authentication cancelled."
        case .failed:         return "Authentication failed. Try again."
        case .lockedOut:      return "Face ID is locked. Use your device passcode to unlock."
        case .unavailable:    return "Biometric authentication is unavailable on this device."
        case .notEnrolled:    return "Face ID or Touch ID is not set up on this device."
        case .passcodeNotSet: return "Set a device passcode to use biometric lock."
        }
    }

    /// Maps an `LAError` to the user-facing outcome.
    ///
    /// Note what is *absent*: there is no case that means "let them in anyway". Every mapped
    /// value leaves the app locked; only an explicit `.success` from the evaluator unlocks it.
    static func from(_ error: LAError) -> BiometricLockError {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:   return .cancelled
        case .biometryLockout, .touchIDLockout:        return .lockedOut
        case .biometryNotEnrolled, .touchIDNotEnrolled: return .notEnrolled
        case .biometryNotAvailable, .touchIDNotAvailable: return .unavailable
        case .passcodeNotSet:                          return .passcodeNotSet
        default:                                       return .failed
        }
    }
}

// MARK: - BiometricAuthService

/// Opt-in Face ID / Touch ID gate on app launch and on encryption-key access
/// (mvp.md Phase 2 — "Face ID / Touch ID").
///
/// ## Policy
///
/// Uses `LAPolicy.deviceOwnerAuthentication`, **not**
/// `.deviceOwnerAuthenticationWithBiometrics`. The biometrics-only policy fails hard on
/// biometry lockout and leaves the user with no route back into their own encrypted files
/// short of deleting the app. `.deviceOwnerAuthentication` falls back to the device passcode
/// automatically. `canEvaluate` is still probed against the biometrics-only policy at *enable*
/// time, so Settings can honestly say "Face ID is not set up" rather than quietly enrolling the
/// user in a passcode-only gate.
///
/// ## Lock vs. obscure
///
/// `isLocked` and `isObscured` are separate on purpose. The app-switcher snapshot is taken on
/// `scenePhase == .inactive`, which fires *before* `.background`, so a grace-period check alone
/// would leak file names into the switcher for anyone with a non-zero grace period. `isObscured`
/// is set on `.inactive` unconditionally; `isLocked` is set on return to `.active` only if the
/// grace period has lapsed.
@MainActor
final class BiometricAuthService: ObservableObject {

    // MARK: - UserDefaults keys

    enum Keys {
        static let enabled             = "biometricLock.enabled"
        static let gracePeriodSeconds  = "biometricLock.gracePeriodSeconds"
    }

    /// Selectable grace periods, in seconds. Default is 60 — an immediate re-lock is genuinely
    /// useful for the paranoid and genuinely infuriating for everyone else.
    static let gracePeriodOptions: [TimeInterval] = [0, 60, 300, 900]
    static let defaultGracePeriod: TimeInterval = 60

    // MARK: - Published state

    /// True when the lock screen must block access to app content.
    @Published private(set) var isLocked: Bool = false

    /// True while the app is inactive/backgrounded — covers the app-switcher snapshot.
    @Published private(set) var isObscured: Bool = false

    /// Result of the most recent failed authentication, for lock-screen copy.
    @Published private(set) var lastError: BiometricLockError?

    /// True while an evaluation is in flight, so the lock screen can disable its retry button.
    @Published private(set) var isAuthenticating: Bool = false

    /// Bound by `BiometricSettingsView`'s toggle. Turning it on probes availability first and
    /// reverts to `false` when biometrics are unusable, so the toggle never lies about being on.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }

            // A refused enable writes `false` back to this same property, re-entering `didSet`.
            // Without this guard the re-entrant pass takes the "user turned it off" branch and
            // clears `lastError` — wiping the very explanation the refusal just recorded, so the
            // toggle would silently flip back with no reason given.
            if isRevertingEnable {
                isRevertingEnable = false
                return
            }

            if isEnabled {
                let availability = availability()
                guard availability.canEnable else {
                    logger.info("enable refused: \(String(describing: availability), privacy: .public)")
                    lastError = Self.enableError(for: availability)
                    isRevertingEnable = true
                    isEnabled = false
                    return
                }
            }
            defaults.set(isEnabled, forKey: Keys.enabled)
            if !isEnabled {
                isLocked = false
                lastError = nil
            }
        }
    }

    private var isRevertingEnable = false

    // MARK: - Settings

    var gracePeriod: TimeInterval {
        get {
            guard let stored = defaults.object(forKey: Keys.gracePeriodSeconds) as? Double else {
                return Self.defaultGracePeriod
            }
            return stored
        }
        set { defaults.set(newValue, forKey: Keys.gracePeriodSeconds) }
    }

    var biometryType: LABiometryType { evaluator.biometryType }

    /// "Face ID" / "Touch ID" / "Biometrics" — for user-facing copy.
    var biometryName: String {
        switch evaluator.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        default:       return "Biometrics"
        }
    }

    // MARK: - Private

    private let defaults: UserDefaults
    private let evaluator: BiometricEvaluating
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "BiometricAuthService")

    /// When the app last went to `.background`. `nil` means "not backgrounded since launch".
    private(set) var lastBackgroundedAt: Date?

    /// When the user last authenticated successfully. Drives the key-access short-circuit.
    private(set) var lastAuthenticatedAt: Date?

    /// Injectable clock so the grace-period tests don't sleep.
    var now: () -> Date = { Date() }

    // MARK: - Init

    init(defaults: UserDefaults = .standard,
         evaluator: BiometricEvaluating = LAContextEvaluator()) {
        self.defaults = defaults
        self.evaluator = evaluator
        self.isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
    }

    // MARK: - Availability

    func availability() -> BiometricAvailability {
        guard FeatureFlags.biometricLock else { return .notAvailable }
        switch evaluator.canEvaluate(.deviceOwnerAuthenticationWithBiometrics) {
        case .success:
            return .available(evaluator.biometryType)
        case .failure(let error):
            switch error.code {
            case .biometryNotEnrolled, .touchIDNotEnrolled: return .notEnrolled
            case .passcodeNotSet:                           return .passcodeNotSet
            default:                                        return .notAvailable
            }
        }
    }

    private static func enableError(for availability: BiometricAvailability) -> BiometricLockError {
        switch availability {
        case .notEnrolled:    return .notEnrolled
        case .passcodeNotSet: return .passcodeNotSet
        default:              return .unavailable
        }
    }

    // MARK: - Lock decision (pure — the part that is actually testable)

    /// Whether returning to the foreground should re-lock the app.
    ///
    /// `lastBackgroundedAt == nil` means the app has not been backgrounded since launch, which
    /// is not a reason to lock — cold-launch locking is handled by ``lockOnLaunch()``.
    static func shouldLock(lastBackgroundedAt: Date?, now: Date, gracePeriod: TimeInterval) -> Bool {
        guard let lastBackgroundedAt else { return false }
        return now.timeIntervalSince(lastBackgroundedAt) >= gracePeriod
    }

    // MARK: - Lifecycle

    /// Locks the app at cold launch when the feature is on. Called once from the app's `.task`.
    func lockOnLaunch() {
        guard FeatureFlags.biometricLock, isEnabled else {
            isLocked = false
            return
        }
        isLocked = true
        lastError = nil
    }

    /// `scenePhase == .inactive` — the moment iOS takes the app-switcher snapshot. Obscuring
    /// here (rather than on `.background`) is what stops file names leaking into the switcher.
    func sceneDidBecomeInactive() {
        guard FeatureFlags.biometricLock, isEnabled else { return }
        isObscured = true
    }

    func sceneDidEnterBackground() {
        guard FeatureFlags.biometricLock, isEnabled else { return }
        isObscured = true
        // The Face ID system prompt itself drops the scene to `.background` and back while an
        // unlock is already in flight. Recording that as a fresh backgrounding would hand
        // `sceneDidBecomeActive()` a timestamp to re-lock against the instant the real unlock
        // succeeds — an unlock-then-instantly-relock cycle that repeats forever. Only a background
        // that starts from an *unlocked* app is a genuine backgrounding.
        guard !isLocked else { return }
        lastBackgroundedAt = now()
    }

    /// `scenePhase == .active`. Clears the switcher obscuring and re-locks if the grace period
    /// has lapsed.
    func sceneDidBecomeActive() {
        guard FeatureFlags.biometricLock, isEnabled else {
            isObscured = false
            isLocked = false
            return
        }
        isObscured = false
        // Mirrors the guard in `sceneDidEnterBackground()`: while already locked (including
        // mid-authentication) there is no decision to make, and re-running `shouldLock` here is
        // what turns the Face ID prompt's own scene transitions into an infinite re-lock loop.
        guard !isLocked, let backgroundedAt = lastBackgroundedAt else { return }
        if Self.shouldLock(lastBackgroundedAt: backgroundedAt, now: now(), gracePeriod: gracePeriod) {
            isLocked = true
            lastError = nil
        }
        lastBackgroundedAt = nil
    }

    /// True when the lock overlay should be on screen.
    var shouldPresentOverlay: Bool { isLocked || isObscured }

    // MARK: - Authentication

    /// Attempts to unlock. Returns whether the app is now unlocked.
    ///
    /// The invariant this method exists to hold: **no failure path unlocks.** Cancel, lockout,
    /// and authentication failure all leave `isLocked == true` with `lastError` populated.
    @discardableResult
    func unlock() async -> Bool {
        guard FeatureFlags.biometricLock, isEnabled else {
            isLocked = false
            return true
        }
        guard !isAuthenticating else { return !isLocked }

        isAuthenticating = true
        defer { isAuthenticating = false }

        let reason = "Unlock Neutrino Drive to access your encrypted files."
        switch await evaluate(reason: reason) {
        case .success:
            isLocked = false
            lastError = nil
            lastAuthenticatedAt = now()
            return true
        case .failure(let error):
            lastError = error
            isLocked = true
            return false
        }
    }

    /// Gate in front of encryption-key access (mvp.md lists "Key access" alongside "App
    /// launch"). Short-circuits to success when the user authenticated within the grace period —
    /// re-prompting someone who unlocked two seconds ago is friction with no security value.
    ///
    /// Deliberately **not** applied to every upload/download: those run unattended (photo
    /// auto-sync, background transfers), where a biometric prompt is either impossible or a
    /// guaranteed failure. The honest boundary is "the app is locked", not "every operation is
    /// individually attested".
    @discardableResult
    func authenticateForKeyAccess() async -> Bool {
        guard FeatureFlags.biometricLock, isEnabled else { return true }

        if let lastAuthenticatedAt,
           now().timeIntervalSince(lastAuthenticatedAt) < gracePeriod {
            return true
        }

        switch await evaluate(reason: "Authenticate to access your encryption keys.") {
        case .success:
            lastAuthenticatedAt = now()
            lastError = nil
            return true
        case .failure(let error):
            lastError = error
            return false
        }
    }

    /// Runs the policy evaluation, retrying once with the passcode-capable policy when the user
    /// explicitly asks for the fallback.
    private func evaluate(reason: String) async -> Result<Void, BiometricLockError> {
        // `.deviceOwnerAuthentication` already presents the passcode sheet on biometric
        // failure, so this single call covers the fallback for almost every case.
        switch await evaluator.evaluate(.deviceOwnerAuthentication, reason: reason) {
        case .success:
            return .success(())
        case .failure(let error):
            if error.code == .userFallback {
                // The user tapped "Enter Passcode" against a biometrics-only prompt (possible
                // when the system downgrades the policy). Re-evaluate explicitly.
                switch await evaluator.evaluate(.deviceOwnerAuthentication, reason: reason) {
                case .success: return .success(())
                case .failure(let retryError): return .failure(.from(retryError))
                }
            }
            return .failure(.from(error))
        }
    }

    // MARK: - Test seams

    #if DEBUG
    func debugSetLastBackgroundedAt(_ date: Date?) { lastBackgroundedAt = date }
    func debugSetLastAuthenticatedAt(_ date: Date?) { lastAuthenticatedAt = date }
    func debugSetLocked(_ locked: Bool) { isLocked = locked }
    #endif
}
