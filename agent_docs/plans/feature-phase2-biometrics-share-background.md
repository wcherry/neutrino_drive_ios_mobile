# Implementation Plan: Phase 2 — Biometric Lock, Share Extension, Background Transfers

Three independent Phase 2 features from `agent_docs/mvp.md`, delivered together
because they share one enabling change: a **shared-storage layer** (App Group +
shared Keychain access group) and a **protocol-level extraction of the E2EE
upload pipeline** out of `UploadService`. Each ships behind its own
`FeatureFlags` entry and can be disabled independently.

> Note on `agent_docs/mvp.md`: the roadmap file is stale. It marks Epics 8/9/10
> and "Photo Auto Backup" as not-done; all four are implemented and merged. This
> plan does not attempt to reconcile the whole file — it only ticks the three
> Phase 2 items it actually delivers.

---

## 1. Face ID / Touch ID

### What is changing and why

Today, anyone holding an unlocked phone has full access to the user's decrypted
Drive: file listings, thumbnails, the offline cache, and the encryption keys in
the Keychain. The keys are the crown jewels — they are what makes the E2EE
guarantee meaningful — and nothing currently stands between a borrowed phone and
`KeyImportService.hasStoredKeys()` returning the private key.

This adds an **opt-in biometric gate**, per mvp.md Phase 2 "Face ID / Touch ID",
protecting both listed targets:

- **App launch** — a full-screen lock overlay until the user authenticates.
- **Key access** — a second gate in front of destructive/revealing key
  operations (Remove Keys), and a re-lock whenever the grace period lapses.

### Layers affected

- **Service — `BiometricAuthService`** *(new — `Services/BiometricAuthService.swift`)*.
  `@MainActor final class BiometricAuthService: ObservableObject`, matching the
  shape of `PhotoSyncService`/`UploadService`. Owns enablement, lock state, the
  grace-period clock, and error mapping.
- **View — `LockScreenView`** *(new — `Views/LockScreenView.swift`)*. The overlay:
  biometry icon, "Unlock Neutrino Drive", retry button, and error copy.
- **View — `BiometricSettingsView`** *(new — `Views/BiometricSettingsView.swift`)*.
  Toggle, grace-period picker, and the unavailable/not-enrolled explanation.
- **View — `SettingsView`** *(modified)*. New "Security" section, flag-gated,
  and the Remove Keys button now goes through the key-access gate.
- **App — `NeutrinoDriveApp`** *(modified)*. Instantiates the service, drives
  `lock()`/`unlock()` from `scenePhase`, and renders the overlay above content.
- **Config — `FeatureFlags`** *(modified)*. Adds `biometricLock`.
- **Config — `project.yml`** *(modified)*. `NSFaceIDUsageDescription`.
- **Tests** — `BiometricAuthServiceTests.swift`.

### Policy choice

`LAPolicy.deviceOwnerAuthentication`, **not** `.deviceOwnerAuthenticationWithBiometrics`.

The distinction matters. `.deviceOwnerAuthenticationWithBiometrics` fails hard on
biometry lockout (five failed Face ID attempts) and leaves the user with no way
back into their own files short of deleting the app. `.deviceOwnerAuthentication`
falls back to the device passcode automatically, which is the only humane
behaviour for a gate that stands between a user and their data. `canEvaluate` is
still probed against `.deviceOwnerAuthenticationWithBiometrics` at *enable* time,
so the Settings toggle can honestly report "Face ID is not set up on this
device" instead of silently enrolling the user in a passcode-only gate.

### Testability seam

`LAContext` cannot be driven from a unit test — there is no way to simulate a
successful Face ID scan in the simulator. The service therefore talks to a
protocol:

```swift
protocol BiometricEvaluating: AnyObject {
    var biometryType: LABiometryType { get }
    func canEvaluate(_ policy: LAPolicy) -> Result<Void, LAError>
    func evaluate(_ policy: LAPolicy, reason: String) async -> Result<Void, LAError>
}
```

Production uses `LAContextEvaluator` (a fresh `LAContext` per evaluation — reusing
one across evaluations caches the last result and is a known source of "it
unlocked without asking me" bugs). Tests inject a fake that returns canned
`LAError`s, which is how the unavailable / not-enrolled / lockout / cancel /
passcode-fallback paths become assertable at all.

### Error handling matrix

| `LAError.Code` | Enable-time behaviour | Unlock-time behaviour |
|---|---|---|
| `biometryNotAvailable` | Toggle refuses to turn on; row explains no biometric hardware | n/a (can't be enabled) |
| `biometryNotEnrolled` | Toggle refuses; deep-link to iOS Settings to enrol | n/a |
| `passcodeNotSet` | Toggle refuses; "Set a device passcode first" | n/a |
| `biometryLockout` | n/a | Stay locked, retry via passcode (`.deviceOwnerAuthentication` already offers it); copy says so |
| `userCancel` / `appCancel` / `systemCancel` | Toggle reverts to off | **Stay locked** — retry button, no bypass |
| `userFallback` | n/a | Re-evaluate with `.deviceOwnerAuthentication` (passcode) |
| `authenticationFailed` | Toggle reverts | Stay locked; retry |

The load-bearing rule: **no error path ever unlocks.** Failure to authenticate
leaves `isLocked == true`. Only an explicit success clears it.

### Grace period and app-switcher leakage

Two separate mechanisms, easy to conflate:

1. **Re-lock on background** — `scenePhase == .background` records
   `lastBackgroundedAt`. On return to `.active`, if
   `now - lastBackgroundedAt >= gracePeriod`, `isLocked = true`. Configurable:
   Immediately / 1 min / 5 min / 15 min, default **1 minute** (persisted as
   `biometricLock.gracePeriodSeconds`). A zero grace period is genuinely useful
   for the paranoid and genuinely annoying for everyone else, hence not the
   default.
2. **App-switcher privacy** — the switcher snapshot is taken on
   `scenePhase == .inactive`, which fires *before* `.background`. A grace-period
   check alone therefore leaks file names into the switcher for any user who set
   a non-zero grace. So `isObscured` is set on `.inactive` independently of the
   lock decision, and the overlay renders whenever `isLocked || isObscured`.
   This is the reason the two flags are separate rather than one `isLocked`.

The pure decision function is extracted so it can be tested without a scene:

```swift
static func shouldLock(lastBackgroundedAt: Date?, now: Date, gracePeriod: TimeInterval) -> Bool
```

### Key access

`authenticateForKeyAccess()` re-uses the same evaluator with a distinct reason
string ("Authenticate to access your encryption keys"). It short-circuits to
success when the app has authenticated within the grace period — re-prompting a
user who unlocked the app two seconds ago is friction with no security value.
When the flag or the toggle is off it is an unconditional no-op, so call sites
need no `if` of their own.

Wired into **Remove Keys** in Settings. Deliberately *not* wired into every
upload/download: those run unattended (photo auto-sync, background transfers) and
a biometric prompt from a suspended background task is either impossible or a
guaranteed failure. The honest security boundary here is "the app is locked", not
"every AES operation is individually attested".

---

## 2. Share Sheet Support

### What is changing and why

mvp.md Phase 2 "Share Sheet Support" and Epic 5's unchecked "Share Sheet" item:
from any app, **Share → Neutrino Drive** uploads the shared items straight into
Drive, end-to-end encrypted, without launching the host app.

### Code-sharing strategy — shared source files, not a framework

The extension needs the E2EE upload protocol byte-for-byte identical to
`UploadService`'s. Two ways to get it:

**(a) Shared framework target.** Move the services into a `NeutrinoDriveKit`
framework both targets link. Correct in the abstract, and wrong here: every type
and member the app touches would need `public`/`open` annotations, which is a
several-hundred-line diff across ten service files, all of it churn unrelated to
the feature. It also introduces a dynamic-framework load into app launch for no
functional gain at this size.

**(b) Include the needed source files in both targets.** XcodeGen supports this
directly (a target's `sources` may list individual files). No access-level
changes, no new module boundary, and — the point — the extension compiles *the
same file* the app compiles, so the two can never drift.

**(b) is chosen.** The correctness property that matters ("the extension's
ciphertext is identical to the app's") is guaranteed by literal file identity,
which is a stronger guarantee than a shared framework's API contract would give.
The cost is that the shared set must be kept small and dependency-light, which
forces the extraction below — itself an improvement.

To make that set small, the encrypt-and-POST pipeline is extracted out of
`UploadService` into:

```swift
// Services/E2EEUploader.swift — no @MainActor, no ObservableObject, no DriveService.
struct E2EEUploader {
    func upload(data: Data, fileName: String, mimeType: String,
                parentFolderID: String?,
                progress: (@Sendable (Double) -> Void)?) async throws -> UploadResult
}
```

`UploadService` keeps its exact public surface and its `isUploading`/`progress`/
`error` publishing, and now delegates the cryptography and networking to
`E2EEUploader`. `UploadSheet` is untouched.

**Files shared with the extension** (7, all leaf-ish):
`E2EEUploader.swift`, `UploadResult`+`UploadError` (in `UploadService.swift`? no
— they move to `E2EEUploader.swift`), `KeychainService.swift`,
`SharedStorage.swift`, `FeatureFlags.swift`, `Config/AppSecrets`-free.
Explicitly **not** shared: `AuthService`, `DriveService`, any `View`.

That requires the storage-key constants to leave `AuthService`/`KeyImportService`
(which are not shared) and move to a new `Config/SharedStorage.swift`. The old
names remain as aliases (`AuthService.accessTokenKey = SharedStorage.Keys.accessToken`)
so no call site or test changes.

### App Group + shared Keychain

- **App Group:** `group.com.neutrino.drive` — for the server-host override in
  `UserDefaults` and for the extension's staging directory.
- **Keychain access group:** `$(AppIdentifierPrefix)com.neutrino.drive.shared` —
  so the extension can read the access token and the sealed-key material.

Both declared in `project.yml` via generated `.entitlements` files for the app
and the extension.

**The migration hazard:** adding `kSecAttrAccessGroup` to a Keychain query
changes the item's identity. Existing users' stored keys live in the *default*
access group and would simply vanish — the app would report "no encryption key"
and demand a re-import. Worse, the unit-test target has no entitlements at all,
so an unconditional access group would turn the 9 known Keychain failures into
~30.

`KeychainService` therefore **probes once, lazily**: it attempts a throwaway
`SecItemAdd` in the shared group and caches whether that succeeded. Where the
entitlement is present (app, extension) it uses the shared group; where it is not
(unit tests, and any build without the entitlement) it resolves to `nil` and
behaves exactly as today. A one-shot migration copies any items found in the
default group into the shared group on first successful probe.

### Extension behaviour

- **Multiple items.** `extensionContext.inputItems` is flattened to a list of
  attachments and processed **sequentially**, with a per-item result row. One
  failure does not abort the rest.
- **Memory.** Share extensions are killed at a far lower footprint than the host
  app — typically ~120 MB against the app's multi-hundred. The photo-sync plan's
  512 MB cap is the *app's* cap and is wildly unsafe here. The extension uses
  `ShareLimits.maxItemBytes = 60 MB`, checked from the file's size attribute
  **before** the bytes are read into memory, and rejects oversize items with
  "Too large to share — upload it from the app instead." Attachments are
  materialised via `loadFileRepresentation` (a file URL) rather than
  `loadDataRepresentation`, so the size check happens before allocation.
- **No key / not signed in.** The extension cannot present the login or key-import
  flow. It shows an explanatory row and offers to open the host app.
- **Biometric gate.** Not applied in the extension. It is a write-only path — it
  never displays existing Drive content — and a locked-out share sheet with no
  way to authenticate is a worse outcome than an unauthenticated upload of a file
  the user just explicitly chose to send.

---

## 3. Background Transfers

### What is changing and why

mvp.md Phase 2 "Background Transfers", and the item called out under
"Known risks" in `feature-photo-auto-sync.md`:

> `URLSession.shared` is not a background session. If the OS suspends the app
> mid-upload, that transfer dies and the entry retries from scratch. For large
> videos on a slow link this can loop indefinitely. … The real fix is a
> `.background` `URLSession` with a delegate … deliberately deferred.

This is that fix. `UploadService` and `DownloadService` move their **blob**
transfers onto a `.background` `URLSessionConfiguration` with a delegate, so a
transfer that is in flight when the app is suspended continues in the system's
transfer daemon and completes (or fails cleanly) rather than dying.

### Design

**New — `Services/BackgroundTransferService.swift`.** `NSObject` conforming to
`URLSessionDelegate`, `URLSessionTaskDelegate`, `URLSessionDataDelegate`, and
`URLSessionDownloadDelegate`. Not `@MainActor` — delegate callbacks arrive on the
session's `delegateQueue` and forcing them onto the main actor would deadlock
against the `async` callers awaiting them.

```swift
func upload(request: URLRequest, fromFile: URL,
            progress: (@Sendable (Double) -> Void)?) async throws -> (Data, HTTPURLResponse)
func download(request: URLRequest,
              progress: (@Sendable (Double) -> Void)?) async throws -> (URL, HTTPURLResponse)
```

**What can and cannot go on a background session.** Three hard constraints, all
of which shape the design:

1. `dataTask` is **not supported** at all on a background session. The small JSON
   calls (`GET /files/{id}/key`, `PUT /files/{id}/key`) therefore stay on a
   normal ephemeral/default session. They are sub-kilobyte and complete in
   milliseconds; there is nothing to gain and a functioning API to lose.
2. Upload bodies must come **from a file**, not from `Data` or a stream. The
   multipart body is therefore written to a temp file first and
   `uploadTask(with:fromFile:)` is used. The temp file is deleted in the
   task-completion path, including on failure.
3. Only **one** session may exist per background identifier per process.
   `BackgroundTransferService.shared` is the single owner; constructing a second
   with the same identifier is undefined behaviour.

**Bridging the delegate to `async`.** State lives behind an `NSLock`-guarded box:

- `continuations: [Int: CheckedContinuation<...>]` keyed by `taskIdentifier`.
- `accumulatedData: [Int: Data]` for upload responses (which arrive via
  `didReceive data`, not via the download delegate).
- `progressHandlers: [Int: (Double) -> Void]`.

Every path resumes its continuation **exactly once** — `didCompleteWithError`
removes the continuation from the map under the lock before resuming, so a
`didFinishDownloadingTo` + `didCompleteWithError` pair cannot double-resume. This
is the single most dangerous part of the change: a double-resume is a hard crash
and a never-resumed continuation is a permanent hang.

**Relaunch after a suspended transfer completes.** iOS relaunches the app in the
background and calls
`application(_:handleEventsForBackgroundURLSession:completionHandler:)`. There is
no live continuation at that point — the process is new. The delegate stores the
completion handler, drains the delegate callbacks, and calls the handler on the
main queue from `urlSessionDidFinishEvents(forBackgroundURLSession:)`. Results
with no waiting continuation are recorded (keyed by the task's `taskDescription`,
which callers set to a stable transfer ID) rather than dropped, so a subsequent
in-app retry can observe that the transfer already succeeded instead of
re-uploading.

**SwiftUI has no app delegate**, so one is added via
`@UIApplicationDelegateAdaptor(AppDelegate.self)` in `NeutrinoDriveApp` purely to
receive that callback — it has no other responsibility.

### Photo sync

`PhotoSyncService` uploads through `UploadService.upload(data:…)`. Because that
method now routes its blob POST through `BackgroundTransferService`, photo sync
inherits background transfers with **no change to `PhotoSyncService` itself** —
the wiring is structural, not a new code path, which is why it cannot silently
fail to apply. `feature-photo-auto-sync.md`'s "Known risks" section is updated to
record that the risk is retired and what remains (the memory cap, which is a
separate problem and is *not* fixed by this change).

The 512 MB size cap **stays**. Background sessions fix suspension, not the fact
that `E2EEUploader` holds plaintext and ciphertext in memory simultaneously.

### Preserving `UploadSheet`

`UploadService.upload(fileURL:)` and `upload(data:…)` keep their signatures,
their `reportsProgress` parameter, and their `isUploading`/`progress`/`error`
publishing. `progress` now reflects **real** bytes-sent (via
`didSendBodyData`) instead of jumping 0 → 1, which is strictly better for the
sheet's `ProgressView` and still satisfies the existing assertions
(`progress == 1` on success; untouched when `reportsProgress: false`).

`UploadService(session:)` remains an injection point: when a session is supplied
(as every existing test does), the service wraps it in a foreground-mode
`BackgroundTransferService` instead of the shared background one. This is what
keeps `MockURLProtocol` working — **`URLProtocol` subclasses are not consulted by
background sessions**, so there is no way to unit-test the real background path
through the existing mock. That limitation is recorded honestly in the acceptance
criteria rather than papered over.

---

## Feature flags

```swift
/// Biometric (Face ID / Touch ID) lock on app launch and key access.
static let biometricLock: Bool = true

/// Share extension upload path. Gates the in-app affordances and the
/// extension's own entry point.
static let shareExtension: Bool = true

/// Route large upload/download transfers through a `.background` URLSession.
/// When false, transfers use a standard foreground session (previous behaviour).
static let backgroundTransfers: Bool = true
```

`backgroundTransfers = false` is a genuine kill switch, not decoration: it swaps
the session configuration and nothing else, so a regression in the background
path can be turned off without reverting the refactor.

## Known risks

- **Continuation lifecycle.** Double-resume crashes; missed resume hangs forever.
  Mitigated by removing-then-resuming under a single lock, and by a
  `didCompleteWithError` path that runs for every task regardless of outcome.
- **Keychain access-group migration.** If the probe wrongly reports success on a
  build without the entitlement, keys become unreadable and the app demands a
  re-import. Mitigated by probing with a real `SecItemAdd`/`SecItemDelete` round
  trip rather than reading `Bundle.entitlements`, and by falling back to the
  default group on *any* failure.
- **Background sessions are untestable in the existing harness.** `URLProtocol`
  is bypassed. Coverage stops at the seam; the real path needs a device.
- **Biometrics cannot be exercised in CI.** No simulator API produces a genuine
  successful evaluation. The fake-evaluator tests prove the state machine, not
  the integration.
- **Share extension memory.** 60 MB is an estimate, not a measured limit; the
  real ceiling varies by device and iOS version. A too-generous cap manifests as
  a jetsam kill with no error shown to the user.
- **Two `.background` identifiers in one app group** (app + extension) must not
  collide; the extension uses `…transfers.share` and does its own short-lived
  uploads rather than sharing the app's session, because an extension's session
  dies with the extension process.

## Testing

- `BiometricAuthServiceTests` — grace-period decision table, error mapping, the
  "no error path unlocks" invariant, obscure-on-inactive, key-access
  short-circuit, disabled-flag no-ops.
- `BackgroundTransferServiceTests` — the async/delegate bridge over a
  `MockURLProtocol`-backed foreground session: upload returns body + response,
  progress is reported monotonically and ends at 1, HTTP errors surface, network
  errors surface, concurrent transfers do not cross-talk, temp files are cleaned
  up.
- `E2EEUploaderTests` — the extracted pipeline still produces the same multipart
  shape (metadata part, optional `folder_id`, file part with plaintext MIME on
  `Content-Type`), and the sealed key is `PUT` to the right path.
- `ShareUploadCoordinatorTests` — item flattening, sequential processing,
  oversize rejection before the bytes are read, per-item error isolation,
  missing-key and missing-token preconditions.
- Existing `UploadServiceTests` / `DownloadServiceTests` / `PhotoSyncServiceTests`
  must pass unchanged — they are the regression net for the refactor.

## Acceptance criteria

Ticked **only** where a passing automated test exercises the criterion end to
end. Anything resting on real biometrics, a real background session, a real share
sheet, or a live server stays unticked and is marked *partial* or *not verified*
with the specific gap named — matching the convention at the bottom of
`feature-photo-auto-sync.md`.

Test-suite status at time of writing: **285 tests, 9 failures** on the
iPhone 15 Pro simulator. All 9 are the pre-existing Keychain-dependent failures
on `main` (`AuthServiceTests.test_refreshTokenIfNeeded_withFreshToken_isNoOp`,
`DownloadServiceTests.test_download_throwsNotAuthenticated_whenTokenAbsentButKeysPresent`,
3× `KeyImportServiceTests`, 3× `KeyQRDecryptServiceTests`). Baseline was
173 tests / the same 9 failures, so this adds **112 tests and no regressions**.
None of the 9 were fixed here and none should be counted as fixed.

### Face ID / Touch ID

- [x] The grace period governs re-locking: no lock inside it, lock at or beyond it, and an
      "Immediately" setting locks with no window at all.
      `test_shouldLock_withinGracePeriod_isFalse`,
      `test_shouldLock_atExactlyGracePeriod_isTrue`,
      `test_shouldLock_beyondGracePeriod_isTrue`,
      `test_shouldLock_withZeroGracePeriod_isTrueImmediately`,
      `test_returningToForeground_afterGracePeriodLapsed_locks`,
      `test_returningToForeground_withinGracePeriod_doesNotLock`.
- [x] **No failure path unlocks.** Cancel, biometry lockout, and authentication failure all
      leave the app locked with the reason recorded.
      `test_unlock_onUserCancel_staysLocked`, `test_unlock_onBiometryLockout_staysLocked`,
      `test_unlock_onAuthenticationFailed_staysLocked`, `test_unlock_onUserFallbackThenCancel_staysLocked`.
- [x] Passcode fallback is always available — the policy used is `.deviceOwnerAuthentication`,
      never the biometrics-only one, and `userFallback` re-evaluates rather than giving up.
      `test_unlock_usesDeviceOwnerAuthentication_soPasscodeFallbackIsAlwaysOffered`,
      `test_unlock_onUserFallback_reEvaluatesWithPasscodePolicyAndCanSucceed`.
- [x] Biometrics unavailable / not enrolled / no passcode ⇒ the toggle refuses to turn on and
      says why, instead of sitting "on" over a gate that cannot run.
      `test_enable_whenNotEnrolled_revertsToOffAndReportsWhy`,
      `test_enable_whenPasscodeNotSet_revertsToOff`,
      `test_enable_whenUnavailable_doesNotPersistEnabledFlag`,
      `test_availability_*` (four cases).
      *(This is where a real bug was caught: the revert re-entered `didSet` and wiped the
      error it had just set, so the toggle flipped back silently. Fixed via `isRevertingEnable`.)*
- [x] `FeatureFlags.biometricLock = false` or the toggle off ⇒ never prompts, never locks,
      never obscures. `test_unlock_whenDisabled_isNoOpAndDoesNotPrompt`,
      `test_authenticateForKeyAccess_whenDisabled_passesWithoutPrompting`,
      `test_sceneDidBecomeInactive_whenDisabled_doesNotObscure`,
      `test_lockOnLaunch_whenDisabled_doesNotLock`,
      `test_disable_clearsLockedState`.
- [x] The key-access gate prompts when stale and short-circuits when the user authenticated
      recently. `test_authenticateForKeyAccess_whenEnabled_promptsAndSucceeds`,
      `test_authenticateForKeyAccess_shortCircuitsWithinGracePeriodOfLastUnlock`,
      `test_authenticateForKeyAccess_promptsAgainOnceGracePeriodHasLapsed`,
      `test_authenticateForKeyAccess_whenEnabledAndCancelled_fails`.
- [ ] A real Face ID / Touch ID scan unlocks the app.
      **Not verified.** No simulator API produces a genuine successful evaluation; every test
      above injects a fake `BiometricEvaluating`. The state machine is proven, the integration
      is not. Needs a device — see the verification doc §1.
- [ ] The app switcher never shows file content while the lock is on.
      *Partial* — `test_sceneDidBecomeInactive_whenEnabled_obscuresContent`,
      `test_shouldPresentOverlay_isTrueWhenObscuredEvenIfUnlocked`, and
      `test_returningToForeground_alwaysClearsObscuring` prove the flag flips at the right
      moments. That the flag actually produces an opaque snapshot in the real switcher is a
      SwiftUI rendering question no test here touches, and it is the single most
      user-visible claim in this feature.
- [ ] Settings shows the Security section only when the flag is on, and Remove Keys goes
      through the gate.
      **Not verified.** SwiftUI conditionals and a `Task` inside an alert button; no view
      tests exist in this project. Correct by inspection only.
- [ ] Five failed Face ID attempts fall through to the passcode rather than stranding the user.
      **Not verified** — biometry lockout cannot be synthesised. The *mapping* of
      `.biometryLockout` is tested; the real lockout is not.

### Share Sheet Support

- [x] Multiple shared items are all processed, in order, one at a time.
      `test_run_processesAllAttachmentsInOrder`, `test_run_reportsProgressAsIndexOfTotal`.
- [x] One failing item does not abort the rest, and each failure names its item.
      `test_run_oneFailureDoesNotAbortTheRemainingAttachments`,
      `test_run_namesTheFailingItem_soTheUserKnowsWhatToReSend`,
      `test_run_recordsFailure_whenTheAttachmentCannotBeMaterialised`.
- [x] Oversize items are rejected **before** their bytes are read, and never uploaded.
      `test_run_checksSizeFromFileAttributes_notFromLoadedBytes` (asserts the size provider is
      consulted and the upload handler is not), `test_run_doesNotUploadOversizeItems`,
      `test_run_rejectsOversizeItems_withAnActionableMessage`,
      `test_run_acceptsItemsAtExactlyTheCap`,
      `test_shareLimit_isFarBelowTheAppsPhotoSyncCap`.
- [x] Not signed in / no encryption key ⇒ an explanation rather than a silent failure.
      `test_preconditions_withoutAccessToken_isNotAuthenticated`,
      `test_preconditions_withoutEncryptionKeys_isNoEncryptionKey`,
      `test_preconditions_withNoAttachments_isNoItems`,
      `test_preconditionErrors_allHaveUserFacingDescriptions`.
- [x] Plaintext copies of shared files are not left in the extension's temp directory.
      `test_run_removesTheMaterialisedFileAfterUpload`.
- [x] The storage-key extraction did not change where credentials are filed.
      `test_authServiceKeys_stillResolveToTheSharedStorageValues`,
      `test_keyImportServiceKeys_stillResolveToTheSharedStorageValues`,
      `test_sharedStorageKeys_matchTheOriginalStringLiterals`.
- [ ] "Share → Neutrino Drive" appears in the share sheet and uploads from any app.
      **Not verified.** The test bundle cannot link an app-extension target, so
      `ShareViewController` — including its attachment flattening — is never executed by any
      test. `ShareUploadCoordinatorTests` mirrors the flattening rule in a local helper and
      *says so in a comment*; if production and the mirror diverge, those tests keep passing.
      Verification doc §2 is the only real coverage.
- [ ] The extension's uploads decrypt correctly in the web app.
      **Not verified** — needs a live server. Structurally the extension compiles the same
      `E2EEUploader.swift` the app does, which is why file identity was chosen over a shared
      framework, but "same source" is an argument, not an observation.
- [ ] Existing users' Keychain items survive the move into the shared access group.
      **Not verified**, and the highest-risk item in this PR. The probe path
      (`containerURL(forSecurityApplicationGroupIdentifier:)` returning `nil` without the
      entitlement) is exercised only implicitly — the test bundle has no App Group, so every
      test runs the *default-group* path and the shared-group path has never executed. An
      upgrade-in-place test on a device is mandatory before shipping.
- [ ] 25 MB is the right cap for a real share extension.
      **Not verified.** It is an arithmetic estimate (~3 copies resident × 25 MB in a ~120 MB
      process), not a measured limit. Too generous manifests as a jetsam kill with no error
      shown at all.

### Background Transfers

- [x] The async/delegate bridge resumes every continuation exactly once, for success,
      HTTP error, and transport failure.
      `test_upload_returnsResponseBodyAndStatus`,
      `test_upload_surfacesNonSuccessStatusToCaller_ratherThanThrowing`,
      `test_upload_throwsTransportError_onNetworkFailure`,
      `test_manySequentialUploads_allResumeExactlyOnce`,
      `test_download_returnsAReadableFileWithTheResponseBody`,
      `test_download_throwsTransportError_onNetworkFailure`.
      *(A real bug was caught here too: foreground mode originally used the caller's
      delegate-less session, so no delegate callback ever fired and every transfer hung
      forever. Fixed by rebuilding the session from the caller's `configuration`.)*
- [x] Concurrent transfers do not cross-talk.
      `test_concurrentUploads_doNotCrossTalk`,
      `test_download_relocatesEachTransferToItsOwnDirectory`.
- [x] The multipart body file — ciphertext of user data — is deleted whatever the outcome, and
      no temp artefacts accumulate.
      `test_upload_deletesTheBodyFileOnSuccess`, `test_upload_deletesTheBodyFileOnFailure`,
      `test_upload_keepsTheBodyFile_whenCallerOptsOutOfCleanup`,
      `test_upload_doesNotLeaveTheMultipartBodyFileOnDisk`.
      *(Also a real find: the body lived in a per-upload subdirectory whose empty husk leaked
      once per upload. Now a flat UUID-named file, so `removeItem` is complete cleanup.)*
- [x] Downloads are relocated out of URLSession's transient location before it is reclaimed.
      `test_download_returnsAReadableFileWithTheResponseBody` (asserts the file still exists
      and its contents match, after `didFinishDownloadingTo` has returned).
- [x] The E2EE protocol is unchanged by the refactor: multipart shape, optional `folder_id`,
      plaintext MIME on the file part, sealed key `PUT` to the right path, and the plaintext
      never appearing in the request body.
      `test_multipartBody_*` (seven cases), `test_upload_postsCiphertext_neverThePlaintext`,
      `test_upload_storesTheSealedKeyWithAPutToTheKeyEndpoint`,
      `test_upload_returnsTheServersMetadata`, `test_upload_throwsServerError_withTheStatusCode`.
- [x] `UploadSheet`'s `isUploading`/`progress` behaviour is preserved.
      The pre-existing `test_upload_reportsProgressFalse_leavesIsUploadingAndProgressUntouched`,
      `test_upload_reportsProgressTrue_setsProgressToOneOnSuccess`, and
      `test_uploadDataPrimitive_andUploadFileURL_produceSameRequestBodyLength_forSameContent`
      all still pass unmodified — they are the regression net for the whole refactor.
- [ ] A transfer in flight when iOS suspends the app actually completes.
      **Not verified — and this is the entire point of the feature.** `URLProtocol` subclasses
      are never consulted by a `.background` session, so no test in this harness can execute
      the real path; every transfer test above runs on a foreground session. The simulator
      also does not suspend apps the way iOS does. Physical device only — verification doc §3.
- [ ] `handleEventsForBackgroundURLSession` delivers a transfer that finished after the app was
      killed, and the orphaned-result claim prevents a duplicate re-upload.
      *Partial* — `test_handleBackgroundEvents_storesTheHandlerWithoutInvokingItImmediately`
      asserts only that the handler is stored rather than fired early. The relaunch path, the
      orphan recording in `didCompleteWithError`, and the claim in `upload(...)` have never
      executed. If the claim is broken, the symptom is a silently duplicated upload.
- [ ] Photo sync's suspension risk is genuinely retired.
      *Partial* — retirement is **structural**: `PhotoSyncService` calls
      `UploadService.upload(data:…)`, which now routes through `BackgroundTransferService`,
      and `PhotoSyncServiceTests` still passes unchanged. But since the background path itself
      is unverified, so is this. Needs the large-video device test.
- [ ] `FeatureFlags.backgroundTransfers = false` still works as a kill switch.
      **Not verified** by any test — the flag is read once when `BackgroundTransferService.shared`
      is constructed, and no test constructs it with the flag off.
