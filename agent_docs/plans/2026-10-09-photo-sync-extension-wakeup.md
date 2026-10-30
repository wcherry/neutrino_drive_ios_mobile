# Plan: Photo sync woken by the Photos background-upload extension (#38, Phase 2)

## Summary
Phase 1 made each photo one self-contained request, so a single wake-up can put a dozen photos
in flight with iOS. Nothing *wakes* the app when a photo is taken, though: it still waits for a
`BGAppRefreshTask` that iOS grants hours apart. iOS 27 launches a
`com.apple.photos.background-upload` extension when the photo library changes. This change adds
one. It does **not** create upload jobs for content: the system would upload the original,
unencrypted bytes. It runs Phase 1's prepare stage itself and hands the encrypted bodies to a
background `URLSession` of its own. It also uses download-only jobs to pull iCloud originals the
export could not read.

Built in full but **off by default** (`FeatureFlags.photoUploadExtension`), because the
questions in the research doc's spike can only be answered on a device. Every invocation is
logged to the App Group, and Settings shows the log, so those answers can be read off a phone
before the flag is turned on. Research: `agent_docs/research/2026-10-09-photo-sync-latency.md`.

## Affected Repos
- `neutrino_drive_ios_mobile`: this change. No backend change: the extension uses Phase 1's
  upload endpoint.

## Tasks
1. **Extension-safe photo sync core.** Move what the extension needs out of the `@MainActor`,
   UIKit-bound `PhotoSyncService.swift`:
   - `PhotoAssetExporter.swift`: `PhotoAssetProviding`, `PhotoAssetExporting`, `PhotoExport`,
     `PHKitAssetExporter`.
   - `PhotoSyncCore.swift`: the defaults keys, the upload/transfer id rules, import metadata,
     the request types and the shared-defaults migration.

   `PhotoSyncService` keeps its names by forwarding to these.
2. **Shared state in the App Group.**
   - Photo sync settings move from `UserDefaults.standard` to the App Group suite, migrated once.
   - The queue file moves to the App Group container, also migrated once.
   - `PhotoSyncQueueStore.update` does read-modify-write under a `flock` held across processes.
     `PhotoSyncService` now mutates through it, so neither process overwrites the other's writes.
3. **Hand-off leases.** `PhotoSyncQueue.Entry.handoff` records which process gave an entry to
   its background session, and when. The other process skips the entry until the lease
   (24 hours) runs out. A process ignores its own leases, because it can see its own session's
   tasks.
4. **Background sessions per process.**
   - `BackgroundTransferService` accepts a shared container identifier. The extension owns
     `com.neutrino.drive.photos.transfers`.
   - When iOS relaunches the app to deliver that session's events, `AppDelegate` attaches to
     the session just long enough to collect them, then invalidates it so the extension can
     reconnect.
   - `E2EEUploader` collects earlier uploads from every session attached in the process.
5. **`PhotoUploadExtensionRunner`** (shared file, unit-tested in the app's test bundle):
   - Checks preconditions, enqueues new assets and refreshes the token.
   - Prepares serially and hands off up to 12 transfers. It returns once everything is handed
     off.
   - Assets bigger than 32 MB are left for the app. iCloud-only assets get a download-only job
     and are tried again on a later run.
   - It records results that land while it is alive, and logs every run.
6. **`NeutrinoDrivePhotoUpload` extension target** (iOS 27, ExtensionKit): a thin
   `PHBackgroundResourceUploadJobExtension` that configures `NeutrinoApp`, acknowledges finished
   download jobs, and runs the runner.
7. **Registration.** `PhotoSyncService` enables the extension via
   `enableUploadJobExtension(options:)` only when all of these hold:
   - the flag is on
   - the device runs iOS 27
   - photo sync is on
   - access is **full**

   `preventsExpensiveNetworkAccess` follows Wi-Fi only. It disables the extension otherwise.
8. **Settings.** When the flag is on, a "Photos Wake-ups" row shows the most recent run and the
   number of runs in the last 24 hours.

## Decisions
- **iOS 27 only.** The iOS 26.1 protocol's `process()` is synchronous, and every step here is
  async. Older systems keep Phase 1's behaviour.
- **No content upload jobs.** They would upload plaintext and break end-to-end encryption.
- **The extension does not `PATCH` dates for an old server.** It has no `DriveService`. The
  backend shipped with Phase 1 stores the dates sent with the upload, and the repair pass covers
  anything older.
- **The extension never resolves the destination folder.** Without a cached folder id it does
  nothing, and the app resolves the folder on its next run.
- **The extension refreshes the access token** through `NeutrinoAuth`. The server's rotation
  grace window already covers the app and the extension presenting the same refresh token.
- **Lease of 24 hours.** A shorter lease risks a second copy of a photo when a slow transfer is
  still running. A longer one delays recovery when the result was lost.
- **32 MB cap in the extension.** Its memory limit is undocumented, and encryption holds about
  three copies of a photo. Bigger assets, mostly videos, go through the app as before.

## Known limitations / spike questions (answer on device before enabling)
- How often is the extension invoked, and for how long? (Read from the Settings row and the
  App Group log.)
- Do transfers it starts complete after it exits, and is the app relaunched to deliver them?
- Does enabling the extension show the user any system UI?
- Will App Review accept the extension without content upload jobs?

## Test Plan
- `PhotoSyncQueueTests`: leases (skipped while live for the other owner, ignored for your own,
  expire, cleared on failure), and `handoff` decoding from an old queue file.
- `PhotoSyncQueueStoreTests`: `update` round trip and migration from Application Support.
- `PhotoUploadExtensionRunnerTests`: preconditions, enqueue, hand-off cap, leases recorded,
  oversized assets left for the app, iCloud-only assets get a download request, results
  recorded, expiry, and the run log.
- `PhotoSyncServiceTests`: entries leased by the extension are skipped; a result delivered for
  an entry only the extension enqueued is collected; settings migrate to the shared suite.
- Manual: `VERIFY.md`, "photo sync extension wake-ups, Phase 2", on a device with the flag on.
