# Manual Verification: Photo Auto-Sync

Automated tests (`PhotoSyncQueueTests`, `PhotoSyncServiceTests`, plus additions to
`UploadServiceTests` and `DriveServiceTests`) cover the queue/backoff logic, constraint
gating, folder resolution, and the `UploadService` refactor without touching PhotoKit or the
network. The steps below exercise the parts that only a real device/simulator with a live
Photos library and (ideally) a running backend can prove: PhotoKit permission handling,
end-to-end encrypt-and-upload of a real asset, background-task behaviour, and recovery from
network/server failures.

## Prerequisites

- [ ] A build installed on a physical device or simulator running iOS 16+ (simulators can't
      exercise real `BGProcessingTask` scheduling — see the note under "Background sync").
- [ ] A Neutrino Drive account with an encryption key already imported (Settings → Encryption
      Key).
- [ ] `FeatureFlags.photoAutoSync` set to `true` (already the default).
- [ ] Access to the web app (or API) for the same account, to inspect/delete the destination
      folder and confirm uploaded files decrypt correctly.
- [ ] A way to add photos to the simulator/device library on demand — Simulator: drag an image
      onto the simulator window, or `xcrun simctl addmedia booted <path>`. Device: use the
      Camera app or share an image into Photos.

## Steps to Verify

### Happy Path — foreground

1. Settings → Photo Sync → "Back Up My Photos" → toggle on.
2. Grant "Allow Full Access" when the permission prompt appears.
3. Confirm the footer text reads "Photos taken from now on will be backed up..." and no
   existing library photos start uploading.
4. Leave the app foregrounded (Files tab or Settings). Take a new photo (or
   `simctl addmedia`).
5. **Expected:** within a few seconds, Settings → Photo Sync status changes to "Uploading
   IMG_....jpg (1 of 1)" then settles on "Up to date · Last synced just now".
6. In Files → My Drive, confirm an "iPhone Photos" folder now exists at the root containing
   the new photo.
7. Open the photo from the iOS app — it should decrypt and render correctly.
8. Open the same file in the web app — it should also decrypt and render correctly (proves
   the server only ever received ciphertext and the DEK was sealed correctly).

### Happy Path — app killed

1. With sync already enabled from the previous section, force-quit the app.
2. Take a new photo (or `simctl addmedia`) while the app is not running.
3. Relaunch the app.
4. **Expected:** the catch-up scan (`fetchPersistentChanges(since:)`) picks up the new asset
   on launch and uploads it without further interaction — check Settings → Photo Sync status
   and confirm the file appears in the "iPhone Photos" folder shortly after launch.

### Manual Sync Now / Retry Failed

1. Settings → Photo Sync → "Sync Now" with the queue empty — confirm it's a no-op (status
   stays "Up to date").
2. Force a few uploads to fail (e.g. point the app at an unreachable server host, or trash the
   destination folder mid-upload — see "Trashed folder" below), take a photo, and wait for the
   backoff to exhaust (or seed `UserDefaults` directly for a faster loop in a debug build).
3. **Expected:** after 5 failed attempts the entry appears in the failed count ("n photos
   failed") and a "Retry Failed" button appears.
4. Fix the underlying issue (restore connectivity), tap "Retry Failed".
5. **Expected:** the failed entry re-queues and uploads successfully; the failed count returns
   to zero.

### Edge Cases

**Airplane mode mid-upload**
1. Enable sync, take a large photo/video so the upload takes a few seconds.
2. Toggle Airplane Mode on while "Uploading ..." is showing.
3. **Expected:** the in-flight upload fails, the entry schedules a retry (30s backoff) rather
   than being marked permanently failed. Status shows "Waiting for Wi-Fi" if Wi-Fi-only is on,
   otherwise it retries automatically once connectivity returns.

**Wi-Fi-only with a cellular connection**
1. Settings → Photo Sync → confirm "Use Wi-Fi Only" is on (default).
2. Turn off Wi-Fi so the device is on cellular only.
3. Take a new photo.
4. **Expected:** status reads "Waiting for Wi-Fi"; the photo is *not* uploaded. My Drive does
   not gain a new file.
5. Reconnect to Wi-Fi.
6. **Expected:** the queued photo drains automatically within a few seconds of the Wi-Fi path
   becoming active (no need to reopen the app or tap Sync Now).

**Limited photo access**
1. Reset the app's photo permission (iOS Settings → Neutrino Drive → Photos → Selected
   Photos), or choose "Select Photos..." at the initial permission prompt instead of "Allow
   Full Access".
2. **Expected:** Settings → Photo Sync shows a "Limited photo access — only selected photos
   will back up" warning with a "Manage Selection" button that opens the system limited-library
   picker.
3. Add a photo to the selected subset via "Manage Selection", then take/import a new photo.
4. **Expected:** only assets within the selected subset are eligible for sync; the warning
   remains visible the whole time access stays limited.

**Permission denied**
1. Fresh install (or reset permissions), toggle "Back Up My Photos" on, and deny the photo
   permission prompt.
2. **Expected:** the toggle reverts to off, status reads "Photo access denied", and an alert
   offers "Open Settings" that deep-links to the app's iOS Settings page.

**Delete the destination folder on the web, then take a photo**
1. With sync enabled and at least one photo already uploaded to "iPhone Photos", open the web
   app and permanently delete (not just trash) the "iPhone Photos" folder.
2. Take a new photo on the device.
3. **Expected:** the upload attempt fails with a 404 against the cached folder ID, the app
   clears `photoSync.folderID`, silently re-resolves (recreating "iPhone Photos" since it no
   longer exists), and the photo uploads successfully into the newly recreated folder — the
   user should not see an error for this case.

**Existing folder name adopted, not duplicated**
1. Before enabling sync, create a folder literally named "iphone photos" (any casing) in the
   web app.
2. Enable Photo Sync on the device (destination left at the default "iPhone Photos") and take
   a photo.
3. **Expected:** exactly one "iphone photos"/"iPhone Photos" folder exists after the upload —
   the existing one is reused, not duplicated.

**Manual UploadSheet unaffected**
1. While a photo-sync upload is in flight in the background, use the "+" button in Files to
   manually upload a different file via `UploadSheet`.
2. **Expected:** `UploadSheet`'s own progress bar behaves exactly as before (0→100% for the
   manual upload only) — it must not jump around or appear to reflect the background photo
   upload's progress.

**Turning sync off**
1. Settings → Photo Sync → toggle "Back Up My Photos" off.
2. **Expected:** no further uploads happen; photos already uploaded remain in Drive
   untouched.

### Background sync (opportunistic — best-effort verification)

`BGProcessingTask` is scheduled opportunistically by iOS and cannot be reliably triggered on
demand on a real device; treat this as a best-effort check rather than a hard pass/fail gate:

1. In Xcode, pause at a breakpoint after `PhotoSyncService.registerBackgroundTask()` runs, or
   use the debugger command below once the app has been backgrounded at least once:
   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.neutrino.drive.photosync"]
   ```
2. **Expected:** the catch-up scan runs, the queue drains (subject to the same Wi-Fi/charging
   constraints as foreground), and `setTaskCompleted(success:)` is called — check the console
   logs (`os.log` category `PhotoSyncService`) for the drain sequence.
3. Confirm a *new* `BGProcessingTaskRequest` is submitted after the run (the plan requires
   rescheduling on every run since iOS grants only one execution per submission).

## Expected Results

- New photos taken after enabling sync appear in Drive's "iPhone Photos" folder (or the
  configured destination) without further user action, both foregrounded and after a
  force-quit + relaunch.
- Photos that existed before enabling sync are never uploaded.
- No photo is ever uploaded twice, including across relaunches and force-quits mid-upload.
- The Settings status line always reflects current reality: syncing, waiting for Wi-Fi/power,
  paused for missing keys, or a failed count with a working retry.
- The server only ever receives ciphertext — uploaded photos decrypt correctly in both the
  iOS viewer and the web app.
- Manual uploads via `UploadSheet` are visually unaffected by background photo sync.
