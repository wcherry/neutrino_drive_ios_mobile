# Implementation Plan: Photo Auto-Sync

## What is changing and why

Today photos only reach Neutrino Drive when the user manually picks them in
`UploadSheet`. This feature adds **automatic, opt-in background sync of new
photos and videos** from the device's photo library into a designated Drive
folder — the "Photo Auto Backup" item in Phase 2 of `agent_docs/mvp.md`.

The user turns the feature on once in Settings. From then on, every asset added
to the photo library (camera capture, screenshot, saved image, imported video)
is encrypted locally and uploaded to a server folder — **"iPhone Photos" by
default** — without further interaction.

Encryption is unchanged: the same DEK-per-file / sealed-key protocol already
implemented in `UploadService` is reused verbatim. The server never sees
plaintext photos.

## Scope

**In scope**
- Opt-in toggle, permission request, and destination-folder configuration in Settings.
- Detection of newly added photo-library assets via PhotoKit change tracking.
- A durable upload queue that survives app termination and retries failures.
- Sync while the app is foregrounded, plus opportunistic background sync via
  `BGProcessingTask`.
- Network/power constraints (Wi-Fi only, charging only) as user settings.
- Sync status surfaced in Settings (queued / uploading / synced / failed counts).

**Out of scope (follow-up work)**
- Backfilling the entire existing library (see "Initial baseline" — MVP syncs
  only assets created *after* the feature is enabled).
- True background `URLSession` transfers (`.background` configuration). See
  "Known risks" — this is the main reason large videos may not complete while
  suspended.
- Two-way sync, deletion propagation, or removing photos from the device.
- Album-scoped or smart-album-scoped selection.
- iCloud Photos "optimised storage" originals being force-downloaded over
  cellular.

## Layers affected

- **Backend (none).** The feature composes existing endpoints:
  `GET /api/v1/drive` (find the folder), `POST /api/v1/drive/folders`
  (create it), `POST /api/v1/drive/files/upload`, and
  `PUT /api/v1/drive/files/{id}/key`.
- **Service — `PhotoSyncService`** *(new — `Services/PhotoSyncService.swift`)*.
  The coordinator: owns enablement state, the PhotoKit observer, the queue, and
  the drain loop. `@MainActor final class PhotoSyncService: ObservableObject`,
  matching the shape of `DriveService` / `UploadService`.
- **Service — `PhotoSyncQueue`** *(new — `Services/PhotoSyncQueue.swift`)*.
  Persistent, deduplicated queue of pending assets keyed by
  `PHAsset.localIdentifier`.
- **Service — `UploadService`** *(modified)*. Extract the encrypt-and-POST body
  into a `Data`-based entry point so PhotoKit assets — which arrive as `Data`,
  not as a file URL — can be uploaded without a temp-file round trip. See
  "UploadService refactor".
- **Service — `DriveService`** *(modified)*. Add
  `func ensureFolder(named:parentID:) async throws -> String` for
  find-or-create of the destination folder, and make `fileWasUploaded` safe to
  call for uploads into folders that are not currently loaded.
- **View — `PhotoSyncSettingsView`** *(new — `Views/PhotoSyncSettingsView.swift`)*.
  The detail screen: enable toggle, destination folder name, constraints,
  status, and a "Sync Now" action.
- **View — `SettingsView`** *(modified)*. Adds a "Photo Sync" section with a
  `NavigationLink` into `PhotoSyncSettingsView`, gated on the feature flag.
- **App — `NeutrinoDriveApp`** *(modified)*. Instantiate `PhotoSyncService` as a
  `@StateObject`, wire its `driveService` / `uploadService` dependencies, and
  register the `BGProcessingTask` handler at launch.
- **Config — `FeatureFlags`** *(modified)*. Add `photoAutoSync`.
- **Config — `project.yml` / `Info.plist`** *(modified)*. Photo library usage
  string, `BGTaskSchedulerPermittedIdentifiers`, and the `processing`
  background mode.
- **Tests** — `PhotoSyncQueueTests.swift`, `PhotoSyncServiceTests.swift`, plus
  additions to `UploadServiceTests.swift` and `DriveServiceTests.swift`.

## Destination folder

Default name: **`iPhone Photos`** — stored as a user-editable string, not
hardcoded at the call site.

Resolution happens lazily, the first time an upload is about to be attempted:

1. If `UserDefaults` holds `photoSync.folderID`, use it.
2. Otherwise `GET /api/v1/drive` and look for a **folder** at the drive root
   whose `name` matches `photoSync.folderName` (case-insensitive compare, so a
   pre-existing "iPhone photos" is adopted rather than duplicated).
3. If not found, `POST /api/v1/drive/folders` with
   `{ name: <folderName>, parentId: null }` and use the returned `id`.
4. Cache the resulting ID in `UserDefaults` under `photoSync.folderID`.

The cached ID is **validated on use**: if an upload fails with a 404 referencing
the folder (user deleted or trashed it on the web), clear `photoSync.folderID`
and re-run resolution once before marking the item failed. This keeps sync
alive across a folder deletion instead of failing every subsequent photo.

If the user renames the destination in Settings, clear `photoSync.folderID` and
re-resolve on the next upload. Already-uploaded photos are **not** moved.

### Persisted settings (`UserDefaults`)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `photoSync.enabled` | `Bool` | `false` | Master switch — opt-in. |
| `photoSync.folderName` | `String` | `"iPhone Photos"` | Destination folder name. |
| `photoSync.folderID` | `String?` | `nil` | Cached server folder ID. |
| `photoSync.includeVideos` | `Bool` | `true` | Sync videos as well as images. |
| `photoSync.wifiOnly` | `Bool` | `true` | Suspend the queue on cellular. |
| `photoSync.whileChargingOnly` | `Bool` | `false` | Suspend unless plugged in. |
| `photoSync.anchorDate` | `Date?` | `nil` | Assets created before this are ignored. |
| `photoSync.changeToken` | `Data?` | `nil` | Archived `PHPersistentChangeToken`. |

## Change detection

Two mechanisms, because neither alone is sufficient.

**1. Live observation (app running).** `PhotoSyncService` registers as a
`PHPhotoLibraryChangeObserver`. On each change notification, fetch assets whose
`creationDate > photoSync.anchorDate` and enqueue any whose `localIdentifier` is
not already in the queue or the completed ledger.

**2. Catch-up on launch / foreground (app was killed).** On iOS 16+,
`PHPhotoLibrary.shared().fetchPersistentChanges(since:)` replays changes since
the stored `PHPersistentChangeToken`, which is exactly the gap the observer
misses. Persist the new token only *after* the resulting assets are durably
enqueued, so a crash mid-enqueue replays rather than drops.

If the token is missing or `fetchPersistentChanges` throws
`PHPhotosError.persistentChangeTokenExpired` (the system prunes old tokens),
fall back to a bounded `PHAsset.fetchAssets` query filtered on
`creationDate > max(anchorDate, lastSuccessfulSyncDate)`. The completed-ledger
dedupe makes this fallback safe to run at any time.

**Initial baseline.** When the user first enables sync, set
`photoSync.anchorDate = Date()` and take a fresh change token. Nothing already
in the library is uploaded. The Settings screen states this plainly ("Photos
taken from now on will be backed up"), because silently uploading a 40 GB
library over the user's data plan is the worst possible default.

## Upload queue

`PhotoSyncQueue` persists to
`Application Support/photo-sync-queue.json` (excluded from iCloud/iTunes backup
via `URLResourceValues.isExcludedFromBackup`). Two collections:

```swift
struct PhotoSyncQueue: Codable {
    struct Entry: Codable, Identifiable {
        let id: String            // PHAsset.localIdentifier
        let creationDate: Date
        var attempts: Int
        var lastError: String?
        var nextAttemptAfter: Date?
    }
    var pending: [Entry]
    var completed: Set<String>    // localIdentifiers already uploaded
    var failed: [Entry]           // exhausted retries; user can retry manually
}
```

- **Dedupe** is on `localIdentifier` across all three collections — the single
  guarantee that a photo is never uploaded twice, and the reason the catch-up
  scan can be run liberally.
- **Ordering** is oldest-`creationDate`-first, so a backlog drains in the order
  the photos were taken.
- **Concurrency** is one upload at a time. Photos are large and the encryption
  step in `UploadService` holds the whole plaintext in memory; parallel uploads
  multiply peak memory for no real throughput gain on mobile links.
- **Retry** is exponential backoff on `attempts`: 30s, 2m, 10m, 1h, 6h. After 5
  attempts the entry moves to `failed` and stops consuming battery. `4xx` other
  than `408`/`429` are treated as permanent and move to `failed` immediately.
- **The ledger is compacted** by dropping `completed` identifiers whose asset no
  longer exists in the library, checked at most once per launch.

## Asset export

For each entry, resolve `PHAsset` from the identifier and export the original:

- **Images:** `PHImageManager.requestImageDataAndOrientation` with
  `PHImageRequestOptions.version = .current`, `.isNetworkAccessAllowed = true`
  (needed for iCloud "optimise storage" assets — but only when the current
  network policy permits, see constraints), `deliveryMode = .highQualityFormat`.
- **Videos:** `PHImageManager.requestAVAsset` / `requestExportSession`, or
  `PHAssetResourceManager.writeData(for:toFile:)` for a byte-exact original.
  Videos go through a temp file rather than in-memory `Data` — a 4K video will
  not fit comfortably in memory alongside its ciphertext.
- **Live Photos:** MVP uploads the **still image only**. The paired video
  resource is dropped; note this in the Settings footer.
- **Edited photos:** upload the *current* (edited) rendition, matching what the
  user sees in Photos.
- **RAW/`.HEIC`:** upload the original bytes unchanged. Do not transcode — the
  file is opaque ciphertext to the server anyway, and transcoding loses data.

**Filename** comes from
`PHAssetResource.assetResources(for: asset).first?.originalFilename`, falling
back to `IMG_<yyyyMMdd_HHmmss>.<ext>` derived from `creationDate` and UTI. MIME
type is derived from the resource's `uniformTypeIdentifier`.

**Name collisions** are not resolved client-side. The server assigns its own ID
and two photos with the same original filename are two distinct files; that
matches how manual upload behaves today.

## UploadService refactor

`UploadService.upload(fileURL:parentFolderID:)` currently reads the file, then
runs steps 2–7 inline. Photo sync needs the same steps 2–7 driven from `Data`
that never had a URL.

Split it:

```swift
// New primitive — everything from encryption onward.
func upload(data: Data,
            fileName: String,
            mimeType: String,
            parentFolderID: String?) async throws -> UploadResult

// Existing signature, now a thin wrapper: security-scoped read + MIME sniff,
// then delegates to the primitive. Behaviour is unchanged for UploadSheet.
func upload(fileURL: URL, parentFolderID: String?) async throws -> UploadResult
```

Two behavioural notes for the new call path:

- The `isUploading` / `progress` published properties drive the manual
  `UploadSheet` UI. Background photo uploads must **not** hijack that sheet's
  state, so the primitive takes a `reportsProgress: Bool = true` parameter;
  `PhotoSyncService` passes `false` and publishes its own progress instead.
- `driveService?.fileWasUploaded(result)` appends to `allItems` unconditionally.
  For a photo uploaded into a folder the user has never opened, this inserts a
  lone child whose siblings were never fetched — the browser then shows a
  partially-populated folder. `fileWasUploaded` must skip the append when no
  items for that `parentID` have been loaded yet.

## Background execution

Registered identifier: `com.neutrino.drive.photosync` (`BGProcessingTaskRequest`,
`requiresNetworkConnectivity = true`, `requiresExternalPower` bound to
`photoSync.whileChargingOnly`).

Lifecycle:
1. At launch, `BGTaskScheduler.shared.register` the handler.
2. Whenever the queue becomes non-empty, or on `scenePhase == .background` with
   pending work, submit a request with `earliestBeginDate = now + 60s`.
3. In the handler: run the catch-up scan, then drain the queue until either it
   is empty or `expirationHandler` fires. On expiration, cancel the in-flight
   upload, persist the queue, call `setTaskCompleted(success:)`, and reschedule.
4. Always reschedule if work remains — the system only ever grants one task per
   submission.

Be honest about what this buys: iOS grants processing tasks opportunistically,
typically overnight while charging on Wi-Fi. A user who takes a photo and locks
their phone will generally see it upload the *next time they open the app*, not
within seconds. The Settings copy should not promise instant backup.

## Constraints and gating

Before each drain the service evaluates:

- **Auth:** access token present (`KeychainService`), else pause silently.
- **Keys:** `KeyImportService.hasStoredKeys()`, else pause and surface
  "Import your encryption key to back up photos" in Settings — without keys
  nothing can be encrypted.
- **Network:** `NWPathMonitor`. If `photoSync.wifiOnly` and the path is
  `.cellular` or `isExpensive`, pause. Resume on the path-update callback, not
  by polling.
- **Power:** if `photoSync.whileChargingOnly` and
  `UIDevice.current.batteryState` is `.unplugged`, pause.
- **Low Power Mode:** if `ProcessInfo.processInfo.isLowPowerModeEnabled`, pause
  background drains (foreground "Sync Now" still works).
- **Storage/iCloud:** if the asset is not local and network access is disallowed
  by the current policy, leave the entry pending — do not count it as a failure.

## Permissions

Add to `project.yml` `info.properties` (and the checked-in `Info.plist`):

```yaml
NSPhotoLibraryUsageDescription: "Neutrino Drive needs access to your photo library to automatically back up new photos to your encrypted Drive."
UIBackgroundModes:
  - processing
BGTaskSchedulerPermittedIdentifiers:
  - com.neutrino.drive.photosync
```

Request `PHPhotoLibrary.requestAuthorization(for: .readWrite)` — `.readWrite`
rather than `.addOnly`, since we read originals. Handle all outcomes:

- `.authorized` — proceed.
- `.limited` — sync works but only over the user-selected subset; show an
  explicit warning in Settings with a "Manage selection" button
  (`PHPhotoLibrary.shared().presentLimitedLibraryPicker(from:)`). Limited access
  silently backing up 4 of 400 photos would be a trust failure.
- `.denied` / `.restricted` — force the toggle back off and deep-link to
  `UIApplication.openSettingsURLString`.

## Settings UI

`SettingsView` gains a section (rendered only when
`FeatureFlags.photoAutoSync`):

```
Photo Sync
  Back Up My Photos            [›]   Off / On · 12 waiting
```

`PhotoSyncSettingsView`:

- **Toggle** "Back Up My Photos" — triggers the permission request on first
  enable, sets the anchor date, and captures the change token.
- **Destination** — a text field prefilled with `iPhone Photos`, footer
  "Photos are uploaded to this folder in your Drive. Encrypted before they
  leave your device."
- **Include Videos** toggle.
- **Use Wi-Fi Only** toggle (default on).
- **Only While Charging** toggle (default off).
- **Status** — one of: "Up to date · Last synced <relative date>",
  "Uploading <name> (n of m)", "Waiting for Wi-Fi", "Waiting to charge",
  "Paused — import your encryption key", "n photos failed".
- **Sync Now** button — foreground drain ignoring the power constraint (but not
  the Wi-Fi constraint, unless the user confirms).
- **Retry Failed** button, shown only when `failed` is non-empty.
- Footer noting Live Photos back up as stills, and that turning the feature off
  leaves already-uploaded photos in Drive.

## Feature flag

`NeutrinoDrive/Config/FeatureFlags.swift`:

```swift
/// Set to true to enable automatic background sync of new photos to Drive.
/// When false, the Photo Sync section is hidden in Settings and no PhotoKit
/// observer or background task is registered.
static let photoAutoSync: Bool = true
```

When `false`, the app must not register the change observer or the BG task, and
must not request photo-library permission — a disabled feature should be
invisible in the permission prompts.

## Known risks / edge cases

- **`URLSession.shared` is not a background session.** If the OS suspends the
  app mid-upload, that transfer dies and the entry retries from scratch. For
  large videos on a slow link this can loop indefinitely. Mitigation for MVP:
  cap auto-sync at a configurable max asset size (default 512 MB) and mark
  oversized assets `failed` with "Too large for automatic backup". The real fix
  is a `.background` `URLSession` with a delegate, which requires restructuring
  `UploadService` around a non-`async` delegate flow — deliberately deferred.
- **Memory.** `UploadService` holds plaintext + ciphertext simultaneously. A
  200 MB video means ~400 MB resident and a likely jetsam kill. Reinforces the
  size cap; streaming secretstream chunking is the follow-up.
- **Duplicate uploads across reinstall.** The queue file lives in Application
  Support and is lost on delete-and-reinstall; the completed ledger goes with
  it. A reinstalled app with the same anchor date could re-upload. Mitigation:
  on enable, set the anchor to `Date()` — a reinstall starts fresh rather than
  re-uploading history.
- **Limited photo access** looks like normal operation but backs up a subset —
  hence the explicit warning above.
- **Screenshots and downloaded images** are photo-library assets and will sync.
  Acceptable and matches iCloud/Google Photos behaviour; a "camera captures
  only" filter (`PHAsset.sourceType == .typeUserLibrary` plus
  `mediaSubtypes`) is a plausible follow-up.
- **Clock skew / `creationDate` in the past.** Imported assets (AirDrop, iTunes
  sync) carry old creation dates and will be filtered out by the anchor even
  though they are *new to the library*. Prefer PhotoKit's change stream as the
  source of truth and use `creationDate` only for the expired-token fallback.
- **Trashed folder.** Covered by the 404 re-resolution path above.
- **User renames the folder on the web.** The cached ID still resolves, so sync
  follows the rename. Correct behaviour; no action needed.

## Testing

Unit tests (no PhotoKit dependency — `PHAsset` is not constructible in tests, so
the service takes an `AssetProviding` protocol that the tests fake):

- `PhotoSyncQueueTests`
  - enqueue dedupes against `pending`, `completed`, and `failed`
  - round-trips through JSON encode/decode
  - drains oldest-first
  - backoff schedule advances on failure; 5th failure moves to `failed`
  - permanent (`403`) failure short-circuits to `failed`
- `PhotoSyncServiceTests`
  - disabled flag ⇒ no observer registration, no permission request
  - Wi-Fi-only + cellular path ⇒ drain is a no-op and queue is untouched
  - missing encryption key ⇒ paused status, nothing dequeued
  - folder resolution: cached ID used; missing ID triggers find-then-create;
    404 clears the cache and retries exactly once
  - successful upload moves the entry from `pending` to `completed`
- `UploadServiceTests` — new `Data`-based primitive produces byte-identical
  output to the URL path for the same content; `reportsProgress: false` leaves
  `isUploading`/`progress` untouched.
- `DriveServiceTests` — `ensureFolder` adopts an existing case-insensitive name
  match instead of creating a duplicate; `fileWasUploaded` does not append into
  an unloaded parent folder.

Manual verification (add to a `feature-photo-auto-sync-verification.md`
alongside, matching the existing verification-doc convention):
take a photo with the app foregrounded; take a photo with the app killed and
reopen; toggle airplane mode mid-upload; enable Wi-Fi-only then take a photo on
cellular; grant limited access; delete the folder on the web and take a photo.

## Acceptance criteria

Status as of the PR #6 merge with `main` (Epics 8/9/10). A box is ticked **only**
when a passing automated test exercises the criterion end to end. Criteria whose
logic is unit-tested but whose real behaviour depends on PhotoKit, a device, or
a live server stay unticked and are marked *partial* — the remaining half is
covered by `feature-photo-auto-sync-verification.md`, which **has not been run
yet**.

- [ ] Settings shows a "Photo Sync" section only when `FeatureFlags.photoAutoSync` is true.
      *Not verified* — SwiftUI conditional, no view test. Correct by inspection only.
- [ ] Enabling the toggle requests photo-library permission; denial reverts the toggle and offers a deep link to iOS Settings.
      *Not verified* — needs a device; `PHPhotoLibrary` is not faked.
- [ ] The destination folder defaults to `iPhone Photos` and is created on the server on first upload if absent.
      *Partial* — creation path covered by `test_ensureFolder_createsNewFolder_whenNoMatchExists`
      against a stubbed `URLProtocol`; the default name is a constant
      (`PhotoSyncService.defaultFolderName`) that no test asserts, and no real
      server has been exercised.
- [x] An existing root folder named `iPhone Photos` (any casing) is adopted, not duplicated.
      `test_ensureFolder_adoptsExistingCaseInsensitiveMatch_insteadOfCreatingDuplicate`.
- [ ] A photo taken while the app is foregrounded is encrypted and uploaded to the destination folder without user action.
      *Partial* — the upload half is covered by
      `test_drain_successfulUpload_movesEntryFromPendingToCompleted` using a fake
      asset provider. No real camera capture has ever driven this path.
- [ ] A photo taken while the app is killed is uploaded on next launch (catch-up scan).
      *Not verified* — `fetchPersistentChanges` catch-up is untested; needs a device.
- [x] Photos existing *before* the feature was enabled are not uploaded.
      `test_newIdentifiers_excludesAssetsBeforeAnchorDate`.
- [ ] No photo is ever uploaded twice, across app relaunches.
      *Partial* — dedupe against `pending`/`completed`/`failed` and queue
      persistence are unit-tested (`test_enqueue_dedupesAgainst*`,
      `test_store_saveThenLoad_roundTripsQueue`). The "across relaunches" claim
      itself has not been observed on a device.
- [ ] Wi-Fi-only ON + cellular connection ⇒ queue holds and status reads "Waiting for Wi-Fi"; it drains on Wi-Fi reconnect.
      *Partial* — the hold and the `.waitingForWiFi` status are covered by
      `test_drain_wifiOnlyWithCellularPath_isNoOpAndQueueUntouched`. Resumption on
      the `NWPathMonitor` reconnect callback is untested.
- [ ] Killing the app mid-queue preserves pending entries; they resume on relaunch.
      *Partial* — persistence round-trips in tests; the kill/relaunch cycle is unverified.
- [x] Uploads that fail retry with backoff and land in a user-visible failed list after 5 attempts, with a working "Retry Failed".
      `test_markFailed_advancesThroughFullBackoffSchedule`,
      `test_markFailed_fifthFailure_movesToFailed`,
      `test_markFailed_permanent_shortCircuitsToFailedImmediately`,
      `test_retryAllFailed_movesEntriesBackToPendingWithResetState`.
      Note: the queue logic is proven; the Settings button that calls it is not.
- [ ] The server receives ciphertext — the destination folder's files decrypt correctly in the web app and open in the iOS viewer.
      *Not verified* — requires a live server and the web app. This is the single
      most important criterion and nothing automated covers it.
- [x] Manual `UploadSheet` progress UI is unaffected while photo sync runs.
      `test_upload_reportsProgressFalse_leavesIsUploadingAndProgressUntouched`
      plus `test_upload_reportsProgressTrue_setsProgressToOneOnSuccess`.
- [ ] `FeatureFlags.photoAutoSync = false` ⇒ no photo permission prompt, no observer, no background task registration.
      *Partial* — `test_start_whenDisabled_setsStatusDisabled` and
      `test_init_whenDisabled_statusIsDisabled` assert the status only. That
      `start()` returns before the observer/authorization calls is argued in a
      comment, not asserted; `registerBackgroundTask()` has no test at all.
