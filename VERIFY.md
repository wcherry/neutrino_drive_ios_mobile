# Manual Verification: photo sync extension wake-ups, Phase 2 (#38)

Plan: `agent_docs/plans/2026-10-09-photo-sync-extension-wakeup.md`. Shipped **off**
(`FeatureFlags.photoUploadExtension = false`). These steps answer the plan's spike questions
before the flag is turned on for everyone; record the answers in the plan.

## Prerequisites

- A **real device on iOS 27** (the Simulator has no Photos extension host). Drive built from
  this branch with `photoUploadExtension` set to `true`, signed in, key imported.
- Photo Sync on with **Full Access** to the library, Wi-Fi only on, and at least one photo
  already backed up — so the destination folder is cached.
- Console.app filtered to the device, processes `NeutrinoDrive` and `NeutrinoDrivePhotoUpload`,
  categories `PhotoUploadExtension`, `PhotoUploadExtensionRunner`, `PhotoSyncService`,
  `PhotoUploadExtensionRegistration`.

## Steps

### Registration

1. Open Drive. → Console: `enabled the Photos upload extension`. Note whether iOS showed **any**
   prompt or banner (spike question 3).
2. Settings → Photo Sync → change access to **Limited**, return to Drive.
   → `disabled the Photos upload extension`. Restore Full Access; reopen Drive → enabled again.
3. Turn Photo Sync off. → disabled. Turn it back on. → enabled.

### Wake-ups (spike questions 1 and 2)

1. Swipe Drive away in the app switcher, lock the phone, wait a minute.
2. Take three photos with the Camera app. Leave the phone locked on Wi-Fi.
   → Within minutes, Console shows `NeutrinoDrivePhotoUpload` start and log `run: 3 handed
   off …`. Note how long after the shot the run began and how long it lasted.
3. Without opening Drive, check the web app. → The three photos arrive, decrypt, and carry the
   time they were taken.
4. Open Drive → Settings → Photo Sync. → **Photos Wake-ups** shows today's runs; the line under
   it describes the last one. Status is "Up to date" and none of the three upload again.
5. Over a normal day of use, note the run count and the delays from step 2.

### Results delivered to the app

1. Take a photo with the phone on a slow link (Network Link Conditioner, "3G"), and leave it.
   → Console: the extension hands the photo off and exits before it finishes. Then
   `NeutrinoDrive` launches in the background (`handleEventsForBackgroundURLSession` for
   `com.neutrino.drive.photos.transfers`) and the photo is marked done. Drive's Settings shows it
   synced without the app having been opened.

### iCloud originals

1. With "Optimize iPhone Storage" on, pick an old photo that is not on the device and include it
   (Include Older Photos → All Photos), then lock the phone.
   → An extension run reports `1 awaiting download`; a later run sends it. No failed attempts.

### Large files

1. Record a 30-second 4K video and lock the phone.
   → The extension run reports `1 left for the app`. The video uploads the next time the app
   runs (open it, or its background refresh), exactly once.

### No duplicates

1. Take ten photos and immediately open Drive, so the app and the extension both run.
   → Ten files on the server, not more. Console shows each photo claimed by one process only.

### Kill switch

1. Build with `photoUploadExtension = false` and open Drive.
   → `disabled the Photos upload extension`; taking photos no longer launches the extension.

## Cleanup

- Set `photoUploadExtension` back to `false` unless the spike answers say otherwise.

---

# Manual Verification: photo sync latency, Phase 1 (#38)

Design: `agent_docs/research/2026-10-09-photo-sync-latency.md`. Backend half:
`wcherry/neutrino` branch `feature/photo-sync-single-request`, which must be deployed first —
see its `VERIFY.md` for the API-level checks.

## Prerequisites

- Backend from `feature/photo-sync-single-request` running locally, or deployed.
- Drive built from this branch on a **real device** (the Simulator neither suspends the app
  nor runs a background `URLSession` the way iOS does), signed in, key imported.
- Photo Sync on, with a few dozen photos to back up: set **Include Older Photos** to
  *Last 7 Days* (or take a burst).
- Console.app filtered to the device, subsystem `com.neutrino.drive`, to watch
  `PhotoSyncService` / `E2EEUploader` / `BackgroundTransferService`.

## Steps

### Happy path — one request per photo

1. Turn on photo sync. Watch the server log or a proxy (Proxyman/Charles).
   → Each photo is **one** `POST /api/v1/drive/files/upload`. There is no
   `PUT /files/{id}/key` and no `PATCH /files/{id}/import-metadata` after it.
2. Open a backed-up photo in Drive.
   → It decrypts and previews, and its date is the date it was **taken**.
3. In the web app, open the same photo.
   → It decrypts there too (the key stored with the upload is the account's key).

### Happy path — a batch goes to iOS at once

1. Queue ~30 photos, open Settings → Photo Sync, and watch Status.
   → "Uploading … (n of 30)" counts up quickly — preparing, not uploading — then reads
   "Sending N photos" while the transfers run. Console shows up to 12 `prepared … body`
   lines before the first `upload succeeded`.
2. As soon as Status reads "Sending N photos", lock the phone and leave it for 10 minutes on
   Wi-Fi.
   → Unlock: every photo that was "Sending" is backed up (Status *Up to date* or fewer
   waiting), although the app was suspended the whole time.

### Transfers that finish while the app is dead

1. Queue ~20 photos. When Status reads "Sending …", lock the phone so iOS suspends the app,
   then wait. (Don't force-quit from the app switcher: iOS cancels a force-quit app's
   background transfers, so that tests nothing.)
2. Console: on the relaunch iOS performs to deliver the transfers, look for
   `recorded orphaned transfer result for upload-photo-sync:…` followed by
   `upload succeeded` — without the app being opened.
3. Open the app.
   → Those photos are not uploaded again: the backup folder has exactly one copy of each.

### Edge cases

1. **Wi-Fi only**: with *Upload on Wi-Fi Only* on, queue photos on Wi-Fi, then switch Wi-Fi
   off while "Sending …" shows. → The transfers pause rather than going over cellular, and
   resume when Wi-Fi returns.
2. **Older server**: point the app at a backend without `feature/photo-sync-single-request`.
   → Photos still back up, decrypt, and get their capture date — via the `PUT /key` and
   `PATCH /import-metadata` follow-ups, which reappear in the proxy.
3. **Expired token**: leave 30+ photos "Sending" on a slow link for over 15 minutes.
   → Late transfers may fail 401 once; they are prepared again on the next drain, not marked
   failed.
4. **Folder deleted**: delete *iPhone Photos* on the web mid-batch.
   → The next photos 404 once, the folder is recreated, and they land in it.

## Cleanup

Delete this section once Phase 1 has shipped and proven stable.

---

# Manual Verification: photo capture dates (#31) and durable upload keys (#33)

## Prerequisites

- Backend running locally (`docker-compose-dev.yml`) or a reachable deployment.
- Drive built from source and signed in, with an encryption key imported on the device.
- A real device for the suspension cases. The Simulator does not suspend an app the way
  iOS does, and `BGTaskScheduler` is unavailable there — everything under "Upload keys"
  below needs hardware.
- No feature flag. Both changes are bug fixes to an existing path.

## Photo capture dates (#31)

### Happy path — a new photo keeps its date

1. Settings → Photo Sync → **Back Up My Photos** on. Grant photo access.
2. Take a photo (or use one already in the library with **Include Older Photos** set to
   *Last 7 Days*).
3. Wait for Status to read *Up to date*, or tap **Sync Now**.
4. Files → open the *iPhone Photos* folder.
   → The photo's date is the date it was **taken**, not today.
5. In the web app, sort My Drive by date (`?orderBy=createdAt`).
   → The photo sorts by capture date.

### Backfill — a year of library spreads across a year

1. Settings → Photo Sync → **Include Older Photos** → *Last Year*.
2. Let the queue drain (this can take a while; **Sync Now** with the app on screen is
   fastest).
3. Sort the backup folder by date.
   → Photos are spread across the days they were shot, not bunched on today.

### Edit dates

1. Edit a photo in Photos.app (crop it), then let it back up.
   → In Drive, *created* is the capture date and *modified* is the edit date.

### A failed patch does not cost the photo

1. Point the app at a host that 500s on `PATCH /drive/files/{id}/import-metadata` (or stop
   the backend right after the upload returns).
2. Back up one photo.
   → The photo appears in Drive, dated today.
   → Photo Sync status is *Up to date*, **not** *1 photo failed*. The queue does not retry
     it, and no duplicate is created.
   → Console shows `import-metadata patch failed for … — the photo is uploaded but keeps
     today's date until Repair Photo Dates is run`.

### Repair Photo Dates

1. On a device with photos backed up by an **older build** (or reproduce: patch out the
   stamp, back up a few photos, restore it).
2. Settings → Photo Sync → **Repair Photo Dates**.
   → A spinner with a running count, then a line like
     `12 repaired, 3 already correct, 1 ambiguous, 2 not on this device`.
3. Re-open the backup folder.
   → The repaired photos now carry their capture dates.
4. Tap **Repair Photo Dates** again.
   → `0 repaired, N already correct` — the second pass changes nothing. This is what makes
     an interrupted pass safe to simply re-run.
5. Force-quit mid-pass and reopen, then run it again.
   → It finishes the remainder; nothing is double-patched.

### Repair — edge cases

1. **Ambiguous names**: two assets on the device with the same `IMG_0001.HEIC`.
   → Counted as *ambiguous* and left alone. Neither file's date changes.
2. **Not on this device**: delete a backed-up photo from the library, then repair.
   → Counted as *not on this device*. Its date stays wrong; this is expected and stated in
     the footer.
3. **Constraints**: Wi-Fi Only on, device on cellular → the row reads *Waiting for Wi-Fi*
   and nothing is requested. Same for *Only While Charging* when unplugged.
4. **Signed out** → *Sign in to repair photo dates.*
5. **Never backed up anything** (no destination folder yet) → *No photo backup folder has
   been created yet.*

### Upgrade from an older build — the queue survives

1. Install the previous build, back up a few photos so `photo-sync-queue.json` has a
   populated `completed` array.
2. Install this build over it, open Settings → Photo Sync.
   → Queued count stays 0 and nothing re-uploads. (A ledger that failed to migrate would
     show the whole library re-queuing — that is the regression this checks for.)

## Upload keys (#33) — needs a real device

### The window itself

1. Share a large file (50 MB+) into Drive from another app, over a slow connection.
2. Dismiss the share sheet the moment the progress bar starts — this kills the extension
   process, which is the case the fix is for.
3. Reopen Drive.
   → Within a second or two, Console shows `reconciled sealed key for <id>`.
   → Open the file in Drive, and in the web app.
   → It decrypts and renders. Before this change it would appear with a working cover
     thumbnail and fail to open anywhere, permanently.

### Photo sync under suspension

1. Photo Sync on, a backlog of several large videos queued.
2. Tap **Sync Now**, then lock the phone and leave it for a few minutes.
3. Unlock and reopen Drive.
   → Every file that finished uploading opens. None is left with a cover but no content.

### No duplicates on retry

1. With a backlog draining, put the phone in Airplane Mode mid-transfer, then restore it.
   → The photo completes once. The backup folder has exactly one copy of it.

### Nothing left behind

1. After all of the above, with everything drained and openable:
   ```
   xcrun simctl get_app_container booted com.neutrino.drive groups
   ```
   (or inspect the App Group container on device) →
   `pending-upload-keys.json` is absent or empty. A record that lingers with a `fileID`
   means a key `PUT` is still failing; a record with no `fileID` is a blob that never
   committed and is discarded after 30 days.

## Cleanup

Delete this file once both fixes are proven on a real device across a few days of ordinary
use.
