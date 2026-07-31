# Manual Verification: Phase 2 — Biometric Lock, Share Extension, Background Transfers

Automated tests (`BiometricAuthServiceTests`, `BackgroundTransferServiceTests`,
`ShareUploadCoordinatorTests`, `E2EEUploaderTests`, plus the pre-existing
`UploadServiceTests` / `DownloadServiceTests` / `PhotoSyncServiceTests` as the regression net)
cover the lock state machine, the async/delegate transfer bridge, share sequencing and size
gating, and the multipart protocol — all without biometrics, a share sheet, or a network.

**Three things in this PR cannot be proven by any test in this repo**, and the steps below are
the only coverage they have:

1. **Biometrics.** No simulator API produces a genuine successful Face ID / Touch ID
   evaluation, and a lockout cannot be synthesised. The tests prove the state machine given a
   result; they do not prove the integration produces those results.
2. **Background transfers.** `URLProtocol` subclasses are never consulted by a `.background`
   `URLSessionConfiguration`, so the real suspension-and-relaunch path is untestable in-process.
   It also requires a **physical device** — the simulator does not suspend apps the way iOS
   does.
3. **The share extension.** The test bundle cannot link an app-extension target, so
   `ShareViewController` itself (attachment flattening from real `NSItemProvider`s, extension
   context completion, the actual memory ceiling) is only exercised here.

## Prerequisites

- [ ] A **physical device** running iOS 16+ with Face ID or Touch ID enrolled and a device
      passcode set. The simulator is sufficient for the share-sheet UI and the Settings screens,
      but not for biometrics or background transfers.
- [ ] A second device or a simulator with **no** biometric enrolment, for the not-enrolled path.
- [ ] A Neutrino Drive account signed in, with an encryption key imported (Settings → Encryption
      Key).
- [ ] A reachable backend, and access to the web app for the same account to confirm uploads
      decrypt correctly.
- [ ] `FeatureFlags.biometricLock`, `.shareExtension`, and `.backgroundTransfers` all `true`
      (the defaults).
- [ ] A large file (≥ 100 MB) available in Files, for the background-transfer steps.
- [ ] Console.app or Xcode attached, filtering the `os.log` subsystem `com.neutrino.drive` —
      several expectations below are only observable in the logs.

---

## 1. Face ID / Touch ID

### Happy path — app launch

1. Settings → Security → App Lock. Confirm the row reads "Off".
2. Toggle "Require Face ID" on. Confirm it stays on and a "Grace Period" picker appears set to
   "After 1 minute".
3. Force-quit the app and relaunch.
4. **Expected:** the lock overlay appears immediately and a Face ID prompt fires automatically
   without tapping anything. No file names, folder names, or thumbnails are visible behind or
   around the overlay at any point.
5. Authenticate successfully.
6. **Expected:** the overlay dismisses and the Files tab appears.

### Grace period

1. With the lock on and grace at "After 1 minute", background the app and return within ~10
   seconds.
2. **Expected:** no authentication prompt; the app resumes where it was.
3. Background the app, wait 90 seconds, return.
4. **Expected:** the lock overlay is up and a prompt fires.
5. Change the grace period to "Immediately", background, and return at once.
6. **Expected:** locked every time, with no window at all.

### App-switcher leakage — the one to be strict about

1. Open Files → My Drive so a list of real file names is on screen.
2. Set the grace period to "After 15 minutes" (i.e. long enough that returning will *not* lock).
3. Swipe up to the app switcher and hold.
4. **Expected:** the Neutrino Drive card shows the plain lock screen — **not** the file list, and
   **not** a blurred file list. A blurred list of file names is still a readable list of file
   names, and this is exactly where that matters.
5. Return to the app.
6. **Expected:** no authentication prompt (still inside the grace period) and the overlay clears
   immediately.
7. Repeat with the app on the Settings tab and on an open file preview.

### Cancel, failure, and lockout

1. With the app locked, dismiss the Face ID prompt (tap Cancel).
2. **Expected:** the app stays locked, "Authentication cancelled." is shown, and an
   "Unlock with Face ID" button is available. **There must be no way to reach file content.**
3. Tap the button, then fail Face ID (cover the sensor / present a wrong face) five times in a
   row to trigger biometry lockout.
4. **Expected:** the message reads "Face ID is locked. Use your device passcode to unlock." and
   the system prompt offers the passcode. Enter the passcode.
5. **Expected:** the app unlocks. (This is the reason the policy is `.deviceOwnerAuthentication`
   and not `.deviceOwnerAuthenticationWithBiometrics` — verify that a locked-out user is never
   stranded.)
6. Force-quit while locked and relaunch.
7. **Expected:** still locked. The lock is not bypassable by restarting.

### Not enrolled / unavailable

1. On a device (or simulator) with **no** Face ID or Touch ID enrolled, go to Settings →
   Security → App Lock.
2. Attempt to turn the toggle on.
3. **Expected:** the toggle reverts to off, an alert explains "Face ID or Touch ID is not set
   up…", and an "Open iOS Settings" button deep-links to the app's Settings page. The toggle must
   never sit in the "on" position while the gate cannot actually run.
4. On a device with **no passcode set**, repeat.
5. **Expected:** "Set a device passcode in iOS Settings to use this."

### Key access

1. With App Lock on, unlock the app, then wait out the grace period (or set it to "Immediately"
   and background/return once).
2. Settings → Encryption Key → "Remove Keys" → confirm "Remove".
3. **Expected:** a Face ID prompt appears *before* the keys are removed. Cancel it.
4. **Expected:** an "Authentication Required" alert appears and the keys are **still present**
   (the row still reads "Encryption Key: Imported ✓").
5. Repeat and authenticate successfully.
6. **Expected:** the keys are removed.
7. Re-import the key, unlock the app, and immediately try "Remove Keys" again within the grace
   period.
8. **Expected:** no second prompt — the recent unlock is honoured. (Verify this is intentional
   and acceptable to you; it is a deliberate friction/security trade.)

### Feature flag off

1. Set `FeatureFlags.biometricLock = false`, rebuild.
2. **Expected:** no "Security" section in Settings, no lock overlay at launch or on return from
   background, no Face ID prompt on "Remove Keys", and no app-switcher obscuring.

---

## 2. Share Sheet Support

### Happy path — single item

1. Open Photos, select one photo, tap Share.
2. **Expected:** "Neutrino Drive" appears in the share sheet's app row (you may need to scroll
   or tap "More" the first time).
3. Tap it.
4. **Expected:** a compact sheet reading "Encrypting and uploading…" with the footnote "Files are
   encrypted on this device before they are sent.", then "Uploaded" and an automatic dismiss
   after about a second.
5. Open the Neutrino Drive app → Files → My Drive.
6. **Expected:** the shared photo is at the Drive root.
7. Open it in the app and in the **web app**.
8. **Expected:** it decrypts and renders correctly in both — this is what proves the extension
   ran the same E2EE protocol as the app and that the server only ever received ciphertext.

### Multiple items

1. In Photos, select **five** photos, Share → Neutrino Drive.
2. **Expected:** the status reads "Uploading 1 of 5…" and counts up to 5.
3. **Expected:** all five appear in My Drive.
4. Repeat from **Files** (multi-select several documents) and from a **third-party app**
   (e.g. share a PDF from Mail, a document from Notes).
5. **Expected:** the same behaviour regardless of source app — multi-select arrives in different
   shapes from different apps and both must flatten to one list.

### Shared Keychain — the migration case

1. **Before installing this build**, have the app installed with an imported key from a previous
   build (this is the upgrade path, and the one that can silently lose keys).
2. Install this build **over** it (do not delete the app).
3. Launch the app once. Confirm Settings still reads "Encryption Key: Imported ✓" — the key must
   survive the move into the shared access group.
4. Now share a file into Neutrino Drive.
5. **Expected:** it uploads. If instead you see "Import your encryption key…", the migration did
   not run — check the logs and do **not** ship.
6. Confirm the app itself still works: browse, download, and open a file.

### Preconditions the extension cannot resolve

1. Sign out of the app (Settings → Sign Out). Share a file into Neutrino Drive.
2. **Expected:** "Can't Upload — Sign in to Neutrino Drive before sharing files." with a Close
   button. No crash, no hang, no silent failure.
3. Sign in, then remove the encryption key. Share a file.
4. **Expected:** "Import your encryption key in Neutrino Drive before sharing files."

### Memory ceiling

1. Share a file larger than 25 MB (e.g. a short 4K video).
2. **Expected:** "Too large to share — upload it from the Neutrino Drive app instead." The
   extension must **not** be killed silently — a jetsam kill looks like the sheet vanishing with
   no message, which is the failure mode this cap exists to prevent.
3. Share a mixed selection: three small photos and one oversize video.
4. **Expected:** "Partly Uploaded — 3 uploaded." followed by a line naming the oversize file
   specifically. The three small photos are in Drive.
5. Share a 24 MB file (just under the cap).
6. **Expected:** it uploads successfully. If the extension dies here, the cap is too generous
   for this device and must be lowered — record the device model and iOS version.

### Partial failure

1. Point the app at an unreachable server host (Login screen → server field), then share three
   files.
2. **Expected:** each failure is listed by name with its own message; the run does not abort on
   the first error.

---

## 3. Background Transfers

**Physical device required.** The simulator does not suspend apps the way iOS does, so none of
this section is meaningful there.

### Upload survives suspension

1. Ensure a slow-ish network (cellular, or Network Link Conditioner set to "3G").
2. Files → "+" → From Files → pick a file ≥ 100 MB.
3. **Expected:** the progress bar advances **smoothly** rather than jumping 0 → 100% — this is
   the visible sign that real `didSendBodyData` reporting is wired up.
4. While the progress bar is mid-way, press Home to background the app. Leave it backgrounded
   for at least a minute.
5. Reopen the app.
6. **Expected:** the upload has continued or completed while backgrounded — it has **not**
   restarted from 0%. In the logs, look for the transfer completing under the
   `BackgroundTransferService` category.
7. Confirm the file appears in My Drive and decrypts correctly in the web app.

### Relaunch delivery

1. Start another large upload and background the app immediately.
2. Force-quit the app while the transfer is still in flight.
3. Wait for the transfer to complete (watch the server, or wait a few minutes).
4. **Expected:** iOS relaunches the app in the background and
   `application(_:handleEventsForBackgroundURLSession:)` fires — visible in the logs as the
   session finishing its events. Confirm the file is present server-side.
5. Reopen the app and start the same upload again.
6. **Expected:** the already-completed result is claimed rather than the bytes being re-sent
   (logged as "claimed result completed while suspended"). If instead it uploads a duplicate,
   the orphan-claim path is not working — record it; it is a correctness issue, not cosmetic.

### Download survives suspension

1. Tap a large file in My Drive to download it.
2. Background the app mid-download; return after a minute.
3. **Expected:** the download completed or continued rather than restarting; the file opens and
   decrypts correctly.

### Photo sync inherits it

1. Settings → Photo Sync → enable, with Wi-Fi-only off so cellular is allowed.
2. Record a video of roughly 100–200 MB.
3. Lock the phone and leave it for several minutes.
4. **Expected:** on reopening, the video has uploaded (or is substantially through) rather than
   sitting at 0 attempts-forever. This is the specific failure the photo-sync plan's "Known
   risks" section named, and this step is the only real proof it is retired.
5. Confirm the still-present 512 MB cap: a >512 MB asset must still land in the failed list with
   "Too large for automatic backup". Background transfers fix suspension, not memory.

### Kill switch

1. Set `FeatureFlags.backgroundTransfers = false`, rebuild.
2. **Expected:** uploads and downloads still work end-to-end (on a foreground session), the
   `UploadSheet` progress bar still fills, and files still decrypt. Only the survive-suspension
   behaviour is gone.

### Regression — `UploadSheet` behaviour

1. With everything on, upload a small file via Files → "+".
2. **Expected:** the sheet shows "Encrypting and uploading…", the progress bar fills, the sheet
   dismisses, and the file appears in the list immediately (optimistic insert).
3. While a photo-sync upload is in flight, do a manual upload.
4. **Expected:** the sheet's progress reflects **only** the manual upload, exactly as before.

---

## Expected Results

- The app cannot be viewed without authentication when App Lock is on — including after a
  force-quit, after a cancelled prompt, and after biometric lockout (where the passcode always
  works).
- The app switcher never shows file content while App Lock is on.
- A user with no biometric enrolment is told why, and the toggle never claims to be on.
- "Share → Neutrino Drive" works from Photos, Files, and third-party apps, for single and
  multiple items, and the results decrypt in the web app — proving the extension runs the same
  E2EE protocol, not a lookalike.
- Existing users' encryption keys survive the move into the shared Keychain access group.
- Oversize shares are rejected with a message rather than by the extension dying.
- Large uploads and downloads survive backgrounding and app termination, and photo sync of a
  large video completes rather than looping.
- Nothing about the manual `UploadSheet` flow changed except that its progress bar is now
  smooth.
