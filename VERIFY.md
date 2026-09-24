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
