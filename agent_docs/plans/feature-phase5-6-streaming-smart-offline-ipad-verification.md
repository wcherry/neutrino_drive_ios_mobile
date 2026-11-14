# Manual Verification: Streaming, Smart Offline Sync, iPad

Automated tests (`SecretStreamCryptoTests`, `EncryptedMediaStreamTests`,
`SmartOfflineSyncTests`, `DriveItemTransferTests`, plus the existing suite as the regression
net) cover the cryptography, the range arithmetic, the caching policy, and the transfer
payloads — 75 new tests, all without a server, a player, or a second app.

**Suite state: 499 tests, 9 failures.** The 9 are the pre-existing Keychain-dependent failures
that were also failing on the parent branch (baseline 424/9); none was fixed here and none is
new. See the plan's acceptance criteria.

Three claims in this PR matter most, and **no test in this repo can prove any of them**:

> 1. That video actually starts playing before it has fully downloaded.
> 2. That the File Provider can now materialize a file far larger than 64 MB without being
>    jetsam-killed.
> 3. That a file dragged into Mail arrives readable, and a file dropped from Files arrives
>    encrypted.

Sections 1, 3, and 5 below are the only coverage for those, and they must be run before this
ships.

## Prerequisites

- [ ] A reachable Neutrino backend **served without a proxy that strips `Range`**. The app fails
      closed on a 200-where-206-was-asked-for, so a stripping proxy produces "This server does
      not support range requests" rather than silent corruption — but you want to know which you
      have.
- [ ] An account signed in on the device with its encryption key imported (Settings →
      Encryption Key reads "Imported ✓").
- [ ] **A video larger than 32 MB** in the Drive, uploaded through this app or the web app.
      A 200–500 MB MP4 is ideal. Below 32 MB the app deliberately downloads instead of
      streaming, so a small clip will *not* exercise the feature.
- [ ] **A file larger than 64 MB but smaller than 2 GB** for §1.5 — ideally the same video.
- [ ] An **iPad** (or iPad simulator) for §3 and §4. Multi-window and drag/drop are absent on
      iPhone by design (`supportsMultipleWindows` is false there).
- [ ] Mail and Files installed and configured, for §3.
- [ ] `FeatureFlags.largeFileStreaming`, `.smartOfflineSync`, `.multiWindow`, `.dragAndDrop`
      all `true` (the defaults).
- [ ] Console.app or Xcode attached, filtering subsystem `com.neutrino.drive`, categories
      `EncryptedMediaStream` / `SmartOfflineSyncService` / `DriveItemTransfer` /
      `E2EEDownloader`.

---

## 1. Large File Streaming

### 1.1 Playback starts before the download completes — the headline claim

1. Put the device on a **deliberately slow connection** (Network Link Conditioner → "3G", or
   just a poor Wi-Fi). This matters: on a fast link everything completes so quickly that
   "streaming" and "downloading" are indistinguishable, and you will learn nothing.
2. Open Files → My Drive and tap the large video.
3. **Expected:** a brief "Preparing stream…" and then **playback begins within a few seconds**,
   long before the whole file could have transferred.
4. **The failure this is looking for:** a progress bar that fills to 100% before anything plays.
   That is the old download path, which means `shouldStream` returned false — check the file is
   actually over 32 MB and that its MIME type starts with `video/`.
5. In the log, confirm a **`bytes=0-23`** request first, then a series of ranged requests. If
   you see one request for the entire blob, streaming is not happening.

### 1.2 Seeking

1. While the video plays, **drag the scrubber to roughly 80%**.
2. **Expected:** playback resumes near that point after a short buffer, **without** having
   fetched the intervening bytes.
3. In the log, confirm a new `Range` request whose offset jumps forward.
4. Scrub **backwards** to 20% and confirm the same.
5. Scrub repeatedly and quickly. **Expected:** no crash, no audio/video desync, no garbled
   frames. Garbled output here would mean a counter/offset bug — stop and do not ship.

### 1.3 The integrity notice is present and honest

1. With the video playing, look below the player.
2. **Expected:** "Streaming decrypts only the parts you play, so this file's integrity check
   can't be completed. Download it to verify it in full."
3. **This is not decoration and must not be removed.** Streamed bytes are genuinely
   unauthenticated — see `EncryptedMediaStream`. A product that encrypts end to end should say
   where it is not checking.

### 1.4 Memory — the property the unit tests could not assert

1. Attach Xcode's **Debug Memory Graph / Allocations** instrument.
2. Download (not stream) a large file — tap a **non-media** file over 100 MB, or set
   `FeatureFlags.largeFileStreaming = false` and open the video.
3. **Expected:** memory stays roughly flat during decryption, rising by megabytes, not by the
   size of the file. Before this branch the same operation allocated roughly **two full copies**
   of the file.
4. **Why this is here and not in a unit test:** the decrypt writes a plaintext file, and those
   dirty pages are charged to the process's resident size. A before/after RSS measurement showed
   growth of exactly the output size — it cannot distinguish "buffered the input" from "wrote
   the output". Only an allocations profile separates them.

### 1.5 The File Provider's 64 MB ceiling is gone

**This is the regression PR #9 explicitly flagged, and the reason the streaming work was
prioritised.**

1. Open the **Files app** → Browse → Neutrino Drive.
2. Navigate to the file **larger than 64 MB**.
3. Tap it.
4. **Expected before this branch:** "This file is too large to open here (… the limit is
   64 MB)."
5. **Expected now:** the file materializes and opens. It may take a while; it must not fail and
   must not kill the extension.
6. Repeat with a file over ~500 MB if one is available.
7. **What is genuinely unverified:** the size at which a real device *does* struggle. The cap is
   now 2 GiB, chosen as a prudence guard on the strength of the memory fix, **not measured**.
   The remaining constraint is disk, not memory — materialization transiently needs about twice
   the file size free. If you can, test near the limit and record what happens.

### 1.6 Fallbacks behave

1. Set `FeatureFlags.largeFileStreaming = false`, rebuild, open the same video.
2. **Expected:** the old download-then-play path, with a progress bar, and **no** integrity
   notice — because that path *is* authenticated.
3. Restore the flag.
4. Open a **small** (< 32 MB) video. **Expected:** downloaded, not streamed — confirm in the log.

### 1.7 Corruption is still caught on the authenticated path

1. If you can reach the server's storage, flip a byte in a stored blob (or use a proxy to
   corrupt the response).
2. Download that file normally (not streamed).
3. **Expected:** "This file failed its integrity check. It may be corrupted, or it may have
   been altered since it was uploaded. It has not been saved." — and **no file is written**.
4. Confirm no partial plaintext is left in the temp directory.

---

## 2. Smart Offline Sync

### 2.1 Opt-in, and off by default

1. Fresh install → Settings.
2. **Expected:** a "Smart Offline" section with "Cache Files Automatically" **off**.
3. **This default is deliberate** — the disk it fills is the user's.

### 2.2 It caches what you actually use

1. Turn the toggle on. Leave "Wi-Fi Only" on, "Only While Charging" off. Set the limit to 100 MB.
2. Open five or six files, opening two or three of them **repeatedly**.
3. Background the app and foreground it again (sync runs on foreground — see §2.6).
4. **Expected:** Status moves to "Caching N files…" then "Up to date", and the Offline tab shows
   the files you opened most.
5. **Expected:** the files you opened *most often* are cached in preference to the ones you
   opened once.

### 2.3 The budget is respected

1. With the limit at 100 MB, keep opening files until more than 100 MB of candidates exist.
2. **Expected:** "Automatic Cache" never exceeds "of 100 MB".
3. Lower the limit to 100 MB from a higher value after caching more, foreground again.
4. **Expected:** the cache shrinks to fit; the lowest-scoring files are dropped first.

### 2.4 A pinned file is never evicted — the invariant that matters

1. Pick a file and choose **Make Available Offline** explicitly.
2. Set the limit low (100 MB) and open many other large files to force eviction pressure.
3. Foreground repeatedly to let several sync passes run.
4. **Expected:** the pinned file is **still in the Offline tab**, still openable, and appears
   under "Files You Pinned" rather than "Automatic Cache".
5. **If it disappears, this must not ship.** An automatic cache that deletes an explicit pin is
   a bug that only surfaces when the user has no signal.

### 2.5 Constraints are honoured

1. Turn **Wi-Fi Only** on and switch the device to **cellular**.
2. **Expected:** Status reads "Waiting for Wi-Fi" and **no data is used**. Watch Settings →
   Cellular → Neutrino Drive to confirm the byte count does not climb.
3. Turn **Only While Charging** on and unplug.
4. **Expected:** Status reads "Waiting for charger" and nothing downloads.
5. Plug in and reconnect Wi-Fi; confirm caching resumes.

### 2.6 Known limit: no background caching

1. Background the app and leave it for an hour without opening it.
2. **Expected:** nothing new is cached.
3. **This is by design, not a bug.** Photo sync already owns the app's one background
   processing-task identifier; competing for it to prefetch a convenience cache is a poor trade.
   Recorded in the plan under "Deliberately NOT built".

### 2.7 Sign-out clears the access history

1. Note which files are being cached, then **sign out**.
2. Sign back in.
3. **Expected:** the ranking starts fresh — a record of what the previous user opened must not
   survive the session. Confirm `Application Support/SmartOffline/file-access.json` is gone
   after sign-out.

---

## 3. Drag and Drop (iPad)

### 3.1 Drag out to Mail — decrypted, and readable

1. On iPad, open Neutrino Drive and Mail side by side (Split View).
2. Compose a new message in Mail.
3. **Touch and hold a file** in Neutrino Drive, then drag it into the Mail body.
4. **Expected:** it attaches, with the correct filename.
5. **Send it to yourself and open the attachment.**
6. **Expected — the assertion that matters:** the file opens correctly. The actual PDF pages,
   the actual image. **Not** ciphertext, not a zero-byte file, not garbage. This is the whole
   point of dragging out.

### 3.2 Dragging is cheap until you drop

1. Pick the **largest** file in the Drive.
2. Start dragging it and hold, watching the network in Xcode's debug gauges.
3. **Expected:** no download begins while merely dragging.
4. Release it over **nothing** (drop it back on the list / cancel).
5. **Expected:** still no download. Only an actual drop into another app triggers the decrypt.

### 3.3 Drag out to Files and Notes

1. Repeat §3.1 into the **Files** app, into a local folder.
2. **Expected:** the decrypted file appears and opens.
3. Repeat into **Notes**.
4. **Expected:** it attaches and previews.

### 3.4 Drop in — encrypted on the way

1. Open Files alongside Neutrino Drive.
2. Drag a document **from Files onto the My Drive list**.
3. **Expected:** a dashed accent-coloured border appears while hovering, then the file uploads
   and appears in the list.
4. **Open it from Neutrino Drive.** Expected: correct content.
5. **Now confirm it was actually encrypted** — open the same file in the **web app**. If the web
   app can decrypt and display it, the E2EE path was used. If the server has plaintext, it was
   not, and this must not ship.
6. Drag **several files at once**. Expected: all upload; one failure does not cancel the others.
7. Drop into the **Trash** or **Shared** section. Expected: nothing happens — drops are only
   accepted in My Drive.

---

## 4. Multi-Window and Stage Manager (iPad)

### 4.1 Two documents at once

1. Touch and hold a file → **Open in New Window**.
2. **Expected:** a second window opens showing that document.
3. From the first window, open a **different** file in a new window.
4. **Expected:** two windows, two different documents, both usable.
5. Confirm the action is **absent on iPhone** — it is gated on `supportsMultipleWindows`.

### 4.2 Scene restoration

1. With two document windows open, force-quit the app from the app switcher.
2. Relaunch.
3. **Expected:** the windows return, showing the same documents, with the correct titles.
4. **What to check specifically:** the title is right *immediately*, before the drive listing
   loads — that is what `DocumentWindowValue` carrying the name and MIME type buys.

### 4.3 Stage Manager

1. Enable **Stage Manager** (Control Centre).
2. Open Neutrino Drive plus two document windows.
3. **Resize each window** through its full range, including very narrow and very wide.
4. **Expected:** the layout adapts — the sidebar collapses when narrow, the split view returns
   when wide. No clipped content, no horizontal scrolling of the whole view, no fixed-width
   element sticking out.
5. Attach an **external display** if available and drag a window to it.
6. **Expected:** it works and remains usable.
7. **Note on scope:** Stage Manager is not an API. "Supporting" it is exactly multi-window plus
   adaptive layout, which is what §4.1–4.3 test. There is no separate Stage Manager feature to
   check, and the plan says so rather than inventing one.

---

## 5. Regression: nothing that already worked is broken

The streaming decrypt sits under **every** download in the app, so this section is not optional.

1. Download and open a **PDF** — correct content.
2. Download and open an **image** — correct content.
3. Download and open a **text file** — correct content.
4. Open a **Neutrino-native** doc (web viewer path) — unaffected.
5. **Make Available Offline**, go into Airplane Mode, open from the Offline tab — correct
   content.
6. Open a **historical version** from Version History — correct content. (This path also goes
   through the changed decrypt.)
7. **Upload** a file and re-download it — round-trips correctly.
8. Upload via the **Share Extension** from Photos — succeeds. (The share extension now compiles
   `SecretStreamCrypto.swift`; the test bundle cannot link an app-extension target, so its build
   is only proven by the app building — confirm it actually runs.)
9. Open a file **from the Files app** (File Provider) — correct content.
10. **Save into** Neutrino Drive from Pages — succeeds.
11. Confirm a **shared** file still opens for a second account (PR #8's path, unchanged here but
    it shares the decrypt).

## 6. What remains unverified after all of the above

Recorded so nobody mistakes this checklist for complete coverage:

- **The exact size at which File Provider materialization fails.** The cap is 2 GiB by
  judgement, not measurement.
- **Behaviour against a `Range`-stripping proxy in production.** The failure mode is tested
  (`test_prepare_throwsWhenServerIgnoresRange`) but the deployment reality is not known.
- **Streamed integrity.** Not a gap to close by testing — it is a documented property of the
  format. Only a chunked secretstream fixes it, which needs backend agreement.
- **Long-running cache behaviour** over weeks: pruning, score drift, manifest growth.
- **The 9 pre-existing Keychain test failures**, untouched by this branch.
