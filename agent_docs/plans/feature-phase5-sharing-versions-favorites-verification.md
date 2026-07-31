# Manual Verification: Phase 5 — Sharing, Version History, Favorites

Automated tests (`SealedKeyCryptoTests`, `SharingServiceTests`,
`VersionHistoryServiceTests`, `FavoritesTests`, plus the pre-existing
`E2EEUploaderTests` / `UploadServiceTests` / `DownloadServiceTests` as the regression net)
cover the DEK re-wrap, the permission/key-share ordering, version decoding and restore, and
the star mutation — all without a server, a second account, or a rendered view.

**One thing in this PR matters more than everything else here, and no test in this repo can
prove it:**

> **A second real user must be able to open a file shared from this app.**

`SealedKeyCryptoTests.test_shareRoundTrip_recipientCanDecryptTheFile` proves the *client-side*
chain — encrypt with a DEK, seal to the owner, unseal, re-seal to a recipient, unseal as that
recipient, decrypt. `SharingServiceTests.test_addPerson_postsDEKResealedToRecipientPublicKey`
proves the bytes actually posted to `key/share` open with the recipient's private key. Neither
proves that the server stores that key ref intact, that the recipient's client reads it from
the same place, or that the public key on file for the recipient is the one their private key
matches. **Section 1 is the only coverage for that, and it must be run before this ships.**

Two further gaps have no automated coverage at all:

1. **The share extension build.** `SealedKeyCrypto.swift` was added to the `NeutrinoDriveShare`
   source list in `project.yml` because `E2EEUploader` now calls it. The test bundle cannot
   link an app-extension target, so only the app target's compile is proven here.
2. **Every SwiftUI view.** `ShareSheet` and `VersionHistorySheet` are exercised nowhere but
   below.

## Prerequisites

- [ ] A reachable Neutrino backend, and the web app for the same deployment.
- [ ] **Two separate accounts** — call them **A** (the sharer, signed in on the device) and
      **B** (the recipient). This is not optional; sharing cannot be verified with one account.
- [ ] **Account B must have signed in to the web app at least once and generated/imported an
      encryption key**, so a Curve25519 public key is registered for it. An account with no
      public key exercises the partial-success path (§1.4), not the happy path.
- [ ] Account A signed in on the device with its encryption key imported
      (Settings → Encryption Key reads "Imported ✓").
- [ ] A second device, simulator, or browser session logged in as B.
- [ ] A file in A's Drive with **several versions** — edit a document in the web app three or
      four times to accumulate them. Automatic snapshots are created on content change.
- [ ] `FeatureFlags.sharing`, `.versionHistory`, and `.favorites` all `true` (the defaults).
- [ ] Console.app or Xcode attached, filtering subsystem `com.neutrino.drive`, categories
      `SharingService` / `VersionHistoryService` / `DriveService`.

---

## 1. Sharing — the E2EE property

### 1.1 Happy path — the one that matters

1. As **A**, open Files → My Drive. Touch and hold a file with real, recognisable content
   (a PDF or an image you can identify at a glance). Choose **Share…**.
2. **Expected:** the share sheet opens showing "Add People", a role picker defaulting to
   Viewer, and "People With Access" listing the owner.
3. Enter **B's email**, leave the role as Viewer, tap **Share**.
4. **Expected:** the row for B appears under "People With Access" with the badge "Viewer", the
   email field clears, and **no warning banner appears**. A warning here means the key was not
   re-wrapped — go to §1.4, do not treat it as success.
5. In the logs, confirm a `POST …/permissions` followed by a `POST …/key/share`, **in that
   order**. If the key share precedes the grant, the server will have rejected it with
   `400 RECIPIENT_NO_ACCESS` and B will not be able to decrypt.
6. Now, as **B** (other device or browser), open Neutrino Drive → Shared with me.
7. **Expected:** the file is listed.
8. **Open it.**
9. **Expected — THE CRITICAL ASSERTION:** the file renders correctly. The actual PDF pages, the
   actual image. **Not** an error, **not** a decryption failure, **not** garbage bytes.
   This single step is the entire point of the feature. If it fails, the key-wrap is wrong and
   this must not ship regardless of how many unit tests pass.
10. Repeat from B on **iOS** as well as the **web app**, if B has the mobile app — the two
    clients read the key ref through different code and both must work.

### 1.2 Roles

1. As A, share a second file with B as **Editor**.
2. **Expected:** B can open *and* modify it.
3. Share a third as **Commenter** and confirm B's access matches.
4. In the sheet, confirm each row's badge shows the role that was actually granted.

### 1.3 Revoking

1. In the share sheet, swipe left on B's row → **Remove**.
2. **Expected:** a confirmation dialog warning that B "may still have a copy", then the row
   disappears.
3. As B, refresh Shared with me.
4. **Expected:** the file is gone.
5. **Understand what this does not do:** if B opened the file before revocation, B already holds
   the DEK. Revocation removes server access, not knowledge. Confirm you are content with that
   trade — it is documented in the plan's "Known gaps", not a bug to file.

### 1.4 Recipient with no encryption key — partial success

1. Create (or use) an account **C** that has **never** imported an encryption key.
2. As A, share a file with C.
3. **Expected:** an **orange warning** reading roughly "Shared with C, but they cannot decrypt
   it yet — they have not set up an encryption key yet. Ask them to sign in…", **and C still
   appears in the People With Access list.**
4. **Expected:** this is presented as a warning, not as a failed share. A plain "success" here
   would be the worst outcome — it would mean a user believes a file is shared and readable
   when it is not.
5. Have C import a key, then share again from A.
6. **Expected:** no warning this time, and C can open the file.

### 1.5 Unknown recipient

1. Share with an email that has no Neutrino account.
2. **Expected:** "No Neutrino account found for …". Confirm in the logs that **no**
   `POST …/permissions` was issued — a permission must not be granted to a resolved-to-nothing
   user.

### 1.6 Folders

1. Touch and hold a **folder** containing at least two files → Share… → add B as Viewer.
2. **Expected:** the sheet shows a note explaining that files inside each need their own key
   shared.
3. As B, open the shared folder.
4. **Expected:** B sees the folder and the file names, but **cannot decrypt the files inside** —
   because no per-file DEK was shared. This is the documented MVP limitation, and the note in
   step 2 is what makes it honest rather than broken.
5. As A, share one of the inner files directly with B.
6. **Expected:** B can now open that one file.

### 1.7 Share links

1. In the share sheet, tap **Create Share Link**.
2. **Expected:** a URL appears with a **Copy Link** button; tapping it shows "Copied".
3. **Expected:** the footer states plainly that a link recipient without their own encryption
   key will not be able to read the contents.
4. Open the link in a logged-out browser.
5. **Expected:** the server grants access to the ciphertext, and the content does **not**
   decrypt. Confirm this matches your expectations for links on an E2EE product before shipping
   the button.
6. Tap **Remove Link**, reload the URL, and confirm access is gone.
7. **Regression, subtle but important:** close and reopen the share sheet on a file that has
   **never** had a link. Confirm via logs that **no** `GET …/share-link` is issued.
   That endpoint *creates* a default link as a side effect, so merely viewing the sheet must
   never touch it. If you see a link appear that you did not create, this has regressed.

---

## 2. Version History

### 2.1 Listing

1. Open a file with several versions → touch and hold → **Version History**.
2. **Expected:** a list newest-first, each row showing a name ("Version 3", or a label if one
   was set), a date, and a size. Named versions carry a bookmark icon.
3. Confirm the ordering matches the web app's.

### 2.2 Viewing a historical version — decryption

1. Tap a version several revisions old.
2. **Expected:** a spinner, then the document opens in the QuickLook viewer showing the **old**
   content, correctly decrypted.
3. **Expected:** the preview's filename is disambiguated, e.g. `Report (v2).pdf` — not the same
   name as the current file.
4. **This is the version-history equivalent of §1.1.** Encrypted bytes rendered as garbage, or
   a "Failed to decrypt" error, means the version blob is not decryptable with the file's
   current DEK — which would indicate a client somewhere rotated the DEK. Record it; it is a
   data-loss class issue, not a UI bug.
5. Repeat for the **oldest** available version. The older the version, the more chances there
   have been for a DEK rotation to have orphaned it.

### 2.3 Restore

1. Note the current content. Restore an older version (swipe → Restore, or context menu).
2. **Expected:** a confirmation dialog explaining the current version is saved to history first.
3. Confirm.
4. **Expected:** the list refreshes and now contains an **additional** entry — the snapshot of
   what was current before the restore.
5. Open the file normally (not through version history).
6. **Expected:** it now shows the restored content, correctly decrypted.
7. Restore the version you just displaced, confirming the round trip is reversible.
8. Verify the same file in the **web app** — content and version list must agree.

### 2.4 Empty state

1. Open Version History on a freshly uploaded file with no revisions.
2. **Expected:** "No Previous Versions" and an explanation, not a spinner or an error.

---

## 3. Favorites

### 3.1 Star and unstar

1. Touch and hold a file → **Add Star**.
2. **Expected:** the menu item flips to "Remove Star" on the next open, immediately.
3. Switch to the **Starred** section (segmented picker on iPhone, sidebar on iPad).
4. **Expected:** the file is listed.
5. Swipe left on it in Starred → **Unstar**.
6. **Expected:** it disappears from the list at once.
7. Star a **folder** and confirm it also appears.
8. Confirm the starred state matches the web app's for the same items, in both directions.

### 3.2 More than five

1. Star **at least eight** items.
2. **Expected:** all eight appear in Starred.
3. This is the specific regression guard for the server's default `limit=5`, which is a Quick
   Access default and would silently truncate the list. Seeing exactly five is the bug.

### 3.3 Offline / failure rollback

1. Enable Airplane Mode. Star a file.
2. **Expected:** the star appears optimistically, then **reverts**, and an error is surfaced.
   A star that stays lit while the server never recorded it is the failure this checks for.
3. Disable Airplane Mode and confirm starring works again.

### 3.4 Persistence

1. Star several items, force-quit the app, relaunch, open Starred.
2. **Expected:** the same items are listed — they are loaded from the server, not local state.

---

## 4. Regression — nothing else moved

The crypto extraction (`SealedKeyCrypto`) changed the internals of both upload and download.
Unit tests cover it, but confirm the real pipeline:

1. Upload a file from Files → "+". Confirm it appears and **opens correctly in the web app** —
   proving the DEK is still sealed the way the rest of the system expects.
2. Download and open an existing file that predates this branch.
3. Make a file available offline, then open it in Airplane Mode.
4. **Share a file into the app from Photos** (the share extension). **Expected:** it uploads
   and decrypts in the web app. This is the only check that the extension still builds and runs
   with `SealedKeyCrypto` in its source list — nothing automated covers the extension target.
5. Confirm photo auto-sync still uploads.

---

## 5. Feature flags

1. Set `FeatureFlags.favorites = false`, rebuild.
   **Expected:** no "Starred" section in the picker or sidebar, and no star action in any
   context menu.
2. Set `FeatureFlags.sharing = false`, rebuild.
   **Expected:** no "Share…" action anywhere, and **no** permission, user-lookup, or key-share
   request in the logs under any interaction.
3. Set `FeatureFlags.versionHistory = false`, rebuild.
   **Expected:** no "Version History" action; ordinary downloads still work.
4. Set all three false and confirm the app behaves exactly as the parent branch does.

---

## Expected Results

- **A file shared from this app opens, correctly decrypted, for a different real user on a
  different device.** Everything else in this document is secondary to that.
- A recipient without an encryption key produces a visible warning and a granted permission —
  never a silent "shared" that cannot be read.
- Sharing a folder is honest about not sharing the keys of the files inside it.
- Opening the share sheet never creates a share link as a side effect.
- Historical versions decrypt and open; restoring is reversible and preserves the displaced
  content as a new version.
- Starred holds more than five items, survives relaunch, and rolls back when the server refuses.
- Upload, download, offline, share-extension, and photo-sync behaviour are unchanged by the
  crypto extraction.
