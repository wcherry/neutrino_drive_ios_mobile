# Research: photo auto-sync latency (#38)

**Date:** 2026-10-09
**Issue:** [wcherry/neutrino_drive_ios_mobile#38](https://github.com/wcherry/neutrino_drive_ios_mobile/issues/38) — "Photo uploads take an unreasonably long time"
**Related:** #31 (capture dates), `agent_docs/plans/feature-photo-auto-sync.md` ("Known risks")
**Status:** Phase 1 shipped (backend + Drive iOS). Phase 2 implemented behind `FeatureFlags.photoUploadExtension` (off) on `feature/photo-sync-extension-wakeup`, pending the on-device spike in `VERIFY.md`; Phase 3 open

## Problem

Photo auto-sync takes hours to back up new photos, where iCloud Photos does it within seconds.
There are two separate causes:

1. **Nothing wakes the app when a photo is taken.**
2. **Once the app is awake, the upload path moves about one photo per wake-up.**

## Why iCloud Photos is instant and we are not

iCloud Photos is a system daemon with privileged scheduling. Drive only runs when iOS gives it
time, and today it has four ways to get that time:

| Trigger | When it fires | Code |
|---|---|---|
| `photoLibraryDidChange` | Only while the process is alive, so never when suspended or force-quit | `PhotoSyncService.swift:1274` |
| `BGAppRefreshTask` (`…photosync.refresh`) | Whenever iOS decides, based on how the user uses the app. Typically hours apart; never after a force-quit | `PhotoSyncService.swift:325` |
| `BGProcessingTask` (`…photosync`) | Usually overnight while charging | `PhotoSyncService.swift:320` |
| `beginBackgroundTask` drain assertion | About 30 seconds after the app leaves the foreground | `PhotoSyncService.swift:985` |

A photo taken while Drive is suspended waits in the queue until the next time iOS happens to wake
the app.

## Why a backlog crawls even when the app is awake

1. **The drain is strictly serial and blocks on each transfer.** `drain()`
   (`PhotoSyncService.swift:951`) awaits `performUpload` for each entry, and that includes
   awaiting the background `URLSession` completion. Once the app is suspended, the next photo
   cannot be exported or encrypted until iOS relaunches the app to deliver the previous
   completion, and iOS rate-limits those relaunches with growing delays. In practice this is
   about one photo per wake-up.

2. **iOS treats uploads started in the background as discretionary.** Setting
   `isDiscretionary = false` (`BackgroundTransferService.swift:127`) only applies to transfers
   started while the app is in the foreground. Apple's documentation for `isDiscretionary` says
   transfers started while the app is in the background are always treated as discretionary,
   so the system may hold them for a better time. *(Recalled from Apple's documentation, not
   re-checked for this note. Confirm it.)*

3. **Each photo makes four sequential network requests:**

   | # | Request | Code |
   |---|---|---|
   | 1 | `GET` the account's published public key | `E2EEUploader.swift:169` |
   | 2 | `POST /api/v1/drive/files/upload` (the encrypted file) | `E2EEUploader.swift:355` |
   | 3 | `PUT /api/v1/drive/files/{id}/key` (the sealed file key) | `E2EEUploader.swift:386` |
   | 4 | `PATCH /api/v1/drive/files/{id}/import-metadata` (capture dates, #31) | `PhotoSyncService.swift:1088` |

   Requests 3 and 4 need the process awake *after* the upload finishes. That dependency is what
   makes cause 1 unavoidable with today's request shape. It is also why `PendingUploadKey`
   reconciliation exists: an upload interrupted between steps 2 and 3 leaves a file nothing can
   decrypt (#33).

   Request 1 is repeated for every photo, even though the published key almost never changes
   during a drain.

4. **The per-photo work is serial too.** The PhotoKit export, thumbnail generation, encrypting
   the whole file in memory (`E2EEUploader.swift:248`) and writing the multipart body to a temp
   file all happen one photo at a time. That is acceptable in the foreground but wasteful in a
   30-second window.

## Apple's new background-upload API

The iOS 27 SDK installed with Xcode 27.0 (`Photos.framework`) ships a system-scheduled upload
mechanism for photo-backup apps:

- **Extension point:** `com.apple.photos.background-upload`
  - `PHBackgroundResourceUploadExtension` (iOS 26.1), with `process()` and `notifyTermination()`
  - `PHBackgroundResourceUploadJobExtension` (iOS 27, replaces the above), with
    `processJobs() async` and `willTerminate() async`
- **Enabling it:** `PHPhotoLibrary.enableUploadJobExtension(options:)` (iOS 27). On iOS 26.1 it
  is `setUploadJobExtensionEnabled(_:)`. It requires **full** photo library access.
- **Upload jobs:** `PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination:resource:)`
  takes a `URLRequest` and a `PHAssetResource`. The system then uploads that resource to the
  request on its own schedule.
  - Jobs move through `registered → pending → succeeded | failed | cancelled`.
  - The number of unacknowledged jobs is capped by `PHAssetResourceUploadJob.jobLimit`.
  - On iOS 26.4+, `responseHeaderFields` and `error` are available once a job finishes.
- **`PHAssetResourceUploadJobOptions.preventsExpensiveNetworkAccess`** (iOS 27) keeps uploads off
  cellular, the equivalent of our Wi-Fi-only setting.
- **`creationRequestForDownloadJob(resource:)`** (iOS 26.4) asks the system to download an
  iCloud-optimised original to the device in the background, without uploading anything.

### Why we cannot use its upload jobs as designed

The system uploads the resource's **original, unencrypted bytes**, and nothing in the API lets
the app transform the body first. Using upload jobs for content would send plaintext photos to
the server, which breaks end-to-end encryption. This option is rejected.

The extension is still useful for two things:

- **A wake-up signal:** iOS launches the extension when the photo library changes, which is the
  trigger we lack today.
- **Download-only jobs:** pulling iCloud originals in advance. Today that download happens inside
  `PHKitAssetExporter` with `isNetworkAccessAllowed`, which is the slowest part of a drain.

## Proposed solution

### Phase 1: one self-contained request per photo (all iOS versions)

This phase changes the backend and Drive iOS. It is worth doing whatever Phase 2 finds.

**Backend (`neutrino`):**

- `POST /api/v1/drive/files/upload` accepts optional multipart fields: `encrypted_file_key`,
  `key_version`, `created_at` and `updated_at`.
- When those fields are present, `finalize_upload` writes the file key and the dates in the same
  transaction as the file row.
- The key is accepted when `key_version` is any key version that is still valid for the account,
  not only the current one. A photo prepared just before a rotation still uploads; key rotation
  then re-wraps it like any other file.
- `created_at` and `updated_at` are accepted from every client, not only photo sync. They are not
  tied to `import_source`.
- The change is additive, so the web, macOS and other iOS clients keep working unchanged.
- The #31 reasoning for a *separate* date `PATCH` does not apply here. That `PATCH` exists because
  writing a body *later* restamps `updated_at`. When the body, the key and the dates are written by
  the same insert, nothing restamps them afterwards.
- `import_source` stays as it is (`photo-sync:<localIdentifier>`). It can be sent the same way.
- Files to change: `neutrino/src/drive/storage/api.rs` (multipart handler, around line 164) and
  `service.rs` (`finalize_upload`, around line 190).

**Drive iOS:**

1. Split the drain into two stages:
   - **Prepare:** export the photo, make the thumbnail, encrypt it, seal the file key, and write
     the multipart body to disk. The body is now *complete*, with the key and dates inside it.
   - **Submit:** hand the body file to `BackgroundTransferService`.
2. Whenever the app has runtime, prepare as many photos as fit, then submit them all at once to
   the background session instead of awaiting each one. iOS carries the queued transfers while
   the app is suspended.
3. When a completion arrives, after a relaunch or not, only bookkeeping is left: mark the queue
   entry done and record the file id. No follow-up network call is needed, so an interrupted
   upload can no longer leave a file without its key, and `PendingUploadKey` reconciliation
   becomes a fallback for older servers.
4. Look up the published key once per batch, not once per photo.
5. At process startup, run a task that scans the photo library the app monitors for changes since
   the last sync and reconciles them against the queue. This catches photos and completions that
   were missed while the process was dead, so `orphanedResults` can stay in memory.
6. Do the preparing and submitting while the app is still in the foreground as much as possible,
   so iOS doesn't treat the large transfers as discretionary.

**Expected effect:** one foreground visit, or one 30-second background window, puts dozens of
photos in flight with iOS instead of one.

### Phase 2: the Photos extension as a wake-up signal (iOS 26.1+/27+)

- Add a `com.apple.photos.background-upload` extension target that does **not** use upload jobs
  for content.
- In `processJobs()`, enumerate new assets, run Phase 1's prepare stage, and submit to a
  background `URLSession`.
  - That session needs a shared container and its own identifier. One identifier per process
    applies.
- Use download-only jobs to pull iCloud originals ahead of the export.
- Gate the feature on availability and full library access. Users with limited access stay on
  today's path.

**Spike first, timeboxed to one or two days.** The SDK headers don't answer these questions:

- How long is the extension allowed to run per invocation, and how often is it invoked?
- Can the extension start its own background `URLSession` that outlives it?
- Will App Review accept the extension being used for wake-ups and download jobs without creating
  upload jobs?
- Can the extension read the user's access token and keys? (Same shared Keychain group and app
  group problem the share extension already solved, `ShareUploadCoordinator`.)

If any of these fails, Phase 1 still stands on its own.

### Phase 3: smaller improvements

- Allow two or three prepare stages to run at once in the foreground. Memory is the limit: videos
  can be up to 512 MB (`maxAssetSizeBytes`).
- Show "N queued with iOS" in Settings, next to "Last Background Run", so users can tell "waiting
  for iOS" apart from "not started".
- Encrypt in chunks (secretstream already supports multiple messages) to cap peak memory for large
  videos. This would change the wire format, so it is coordinated with
  `chunked-file-encryption.md`. Optional.

## Cross-repo impact

- **`neutrino` (backend):** the additive multipart fields described in Phase 1. No migration is
  needed if the file key and dates go to existing columns. Confirm against the schema.
- **`neutrino_drive_ios_mobile`:** Phase 1 drain refactor and Phase 2 extension target
  (`project.yml`, entitlements, app group).
- **Web, macOS and the other iOS apps:** no change required. They could adopt the single-request
  upload later.
- **Encryption format:** unchanged. The same secretstream and `crypto_box_seal` envelope is sent,
  just in fewer requests.

## Decisions (2026-10-09)

These were open questions; the answers are folded into Phase 1 above.

1. **Can `finalize_upload` store the sealed key in the same transaction without breaking the
   key-rotation invariants in `neutrino/agent_docs/key-rotation.md`?**
   Yes. The key is stored in the same transaction even when it was sealed to an older key version,
   as long as that version is still valid for the account.
2. **Should `created_at`/`updated_at` on upload be limited to photo sync, or allowed for every
   client?**
   Every client. The fields are not gated on `import_source`.
3. **How does `BackgroundTransferService` keep an orphaned result across process death?**
   `orphanedResults` stays in memory only. Instead of persisting it, a task at process startup
   scans the monitored photo library for changes and reconciles them with the queue, so anything
   lost with the process is picked up again.
