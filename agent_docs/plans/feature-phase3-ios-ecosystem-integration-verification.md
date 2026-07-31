# Manual Verification: Phase 3 — iOS Ecosystem Integration

Automated tests (`FileProviderIdentifierTests`, `FileProviderItemTests`,
`DriveAPIClientTests`, `SpotlightIndexServiceTests`, `IncomingDocumentTests`,
plus the pre-existing `DownloadServiceTests` / `E2EEUploaderTests` as the
regression net) cover the identifier mapping, item construction, request shapes,
the Spotlight attribute set, and open-in-place classification — all without a
device, a server, or the Files app.

**The gap in this branch is unusually large, and it has to be stated first:**

> **A File Provider extension cannot be exercised from a unit-test host at all.**

It is loaded by `fileproviderd`, in its own process, against a registered domain,
driven by the real Files app. XCTest cannot instantiate
`NSFileProviderReplicatedExtension`, cannot call its completion-handler methods,
and cannot observe its enumerations. **Nothing in `NeutrinoDriveTests/` proves
that the extension enumerates, materializes, uploads, renames, or deletes
anything.** What is proven is the pure logic underneath it — which is precisely
why that logic was factored out into files both targets compile.

What *is* mechanically verified beyond the unit tests: **the extension compiles
and links**, because `xcodebuild` builds it as an embedded dependency of the app
target, and the built `.appex` was confirmed present in `PlugIns/` with the
expected `NSExtensionPointIdentifier`. That catches the failure mode Phase 5
could not catch for the share extension (a missing `project.yml` source entry
breaks the extension build alone). It says nothing about behaviour.

Sections 1 and 2 below are therefore the *only* coverage for the headline feature
of this branch, and they must be run before it ships.

## Prerequisites

- [ ] A reachable Neutrino backend, and the web app for the same deployment.
- [ ] **A real device, or at minimum a simulator running the Files app.** A File
      Provider domain cannot be exercised from a test host.
- [ ] Signed in on the device **with the encryption key imported**
      (Settings → Encryption Key reads "Imported ✓"). The domain is not
      registered unless both are true — that is by design, and §1.1 checks it.
- [ ] A drive containing: nested folders at least two deep, a PDF, an image, a
      file **larger than 64 MB**, and a Neutrino-native doc.
- [ ] Pages (or Numbers/Word/Excel) installed, for §2.
- [ ] `FeatureFlags.filesAppIntegration`, `.openInPlace`, and `.spotlightSearch`
      all `true` (the defaults).
- [ ] A `.json` key file stored in **iCloud Drive** (not in Neutrino), for §3.
- [ ] Console.app or Xcode attached, filtering subsystems `com.neutrino.drive`
      and `com.neutrino.drive.fileprovider`.

---

## 1. Files App Integration — the headline claim

### 1.1 The domain appears, and only when it should

1. Sign out of the app entirely. Open the **Files** app → Browse.
2. **Expected:** no "Neutrino Drive" location. A location that appears for a
   signed-out user would fail every enumeration with no way for the user to tell
   a broken product from an unconfigured one.
3. Sign in, but **do not** import an encryption key (remove it in Settings if
   present). Return to Files → Browse.
4. **Expected:** still no "Neutrino Drive". Listing files that can never be
   decrypted is worse than showing nothing.
5. Import the encryption key. Return to Files → Browse, pull to refresh.
6. **Expected — the headline assertion:** **"Neutrino Drive" is listed as a
   location.** If it is not, nothing else in this section can be checked.
   Toggle it on under Browse → ⋯ → Edit if it is present but hidden.

### 1.2 Enumeration

1. Tap **Neutrino Drive**.
2. **Expected:** the drive root's folders and files, matching what the app's
   My Drive shows and what the web app shows.
3. Confirm **folders are navigable** and files are not — a folder rendered as a
   zero-byte document means it is reporting a `documentSize` it should not.
4. Navigate two levels deep. Confirm each level enumerates.
5. Confirm file sizes and modification dates match the app's.
6. **Watch for duplicates or missing rows.** A file and a folder that happen to
   share an underlying ID would collide without the `f:`/`d:` identifier
   prefixes; this is where that would surface.

### 1.3 Materialization — decryption through the extension

1. Tap a **PDF** with recognisable content.
2. **Expected — the critical assertion:** the PDF opens in the Files app preview
   and **renders correctly**. Not an error, not a spinner that never resolves,
   **not garbage bytes**. Garbage means the extension's decrypt has diverged from
   the app's, which should be impossible — it compiles the same
   `E2EEDownloader.swift` — but it is the single thing most worth confirming.
3. Repeat with an **image**.
4. Open the same PDF in the app. Confirm identical content.
5. Open a **Neutrino-native doc** (`.neutrino.doc`).
   **Expected:** the Files app does not claim to know how to render it. Only the
   app can. This is `contentType` resolving to `.data`, which is intended.

### 1.4 The 64 MB ceiling — a known, deliberate failure

1. Tap the file **larger than 64 MB**.
2. **Expected:** an error, reasonably promptly, mentioning that the file is too
   large to open here and to use the Neutrino Drive app instead.
3. **Expected:** the Files app does **not** hang, and the extension does **not**
   crash. A crash here means the size guard was bypassed and the process was
   jetsam-killed — which the Files app reports as an uninformative generic
   failure with no hint that size was the cause. That is the outcome the guard
   exists to convert into a readable message.
4. Open the same file **in the app**. **Expected:** it opens fine. The limit is
   the extension's memory budget, not the file.

### 1.5 Create, rename, move, delete

1. In Files → Neutrino Drive, create a **new folder**. Confirm it appears in the
   app and in the web app.
2. Drag a file from another location into Neutrino Drive.
3. **Expected:** it uploads, and — **critically** — opens correctly **in the web
   app**. That proves it was encrypted with the user's DEK on the way in. A file
   that arrives readable-as-plaintext on the server is a silent E2EE hole and
   must block this branch.
4. **Rename** a file in Files. Confirm the new name in the app; confirm it did
   **not** move to the drive root. (`folderId` is three-state — absent, null,
   or an ID — and an accidental `null` on rename would relocate it. Tested at the
   client layer; this is the end-to-end check.)
5. **Move** a file between folders in Files. Confirm in the app.
6. **Delete** a file in Files.
7. **Expected:** it disappears from Files, and appears in the app's **Trash** —
   *not* permanently deleted. Confirm it can be restored.
8. **Understand the mismatch:** the Files app says "Delete" and means it;
   Neutrino trashes instead, deliberately, because a mis-swipe in a system UI
   must not destroy an E2EE file no backup can recover. Emptying Trash in the
   Files app does **not** empty Neutrino's trash.

### 1.6 Editing is read-only — confirm it fails visibly, not silently

1. Open a Neutrino file in an editor that can save in place (Pages, or Files'
   own markup on a PDF). Attempt to edit and save.
2. **Expected:** the system refuses, because `.allowsWriting` is not advertised.
3. **The failure to watch for:** an edit that *appears* to save and is then lost.
   If that happens, capabilities and the backend have diverged and this must be
   fixed before shipping — silent data loss is worse than a refusal.

### 1.7 Remote changes — the documented limitation

1. In the **web app**, create a new file in a folder you have open in Files.
2. **Expected:** Files does **not** update on its own. There is no push and no
   background sync.
3. Navigate out of the folder and back, or pull to refresh.
4. **Expected:** the new file now appears.
5. **This is by design, not a defect to file.** The backend has no change feed,
   so `enumerateChanges` reports `syncAnchorExpired` and forces re-enumeration.
   Confirm you are content with this before shipping; closing it requires a
   backend delta endpoint.

### 1.8 Signed-out and expired-token behaviour

1. Sign out in the app. Return to Files.
2. **Expected:** the Neutrino Drive location disappears.
3. Sign back in, then force the access token to expire (or wait it out) and
   browse in Files **without** opening the app.
4. **Expected:** a clear authentication error, not a hang and not a generic
   failure. The extension cannot refresh tokens by design — two processes racing
   over one refresh token would invalidate the app's session too.
5. Open the app to refresh, return to Files, confirm browsing resumes.

---

## 2. Document Provider

**There is no separate Document Provider target, deliberately.** The legacy
`UIDocumentPickerExtensionViewController` extension point was deprecated in
iOS 11 and is unavailable at this project's iOS 16 floor; since iOS 11 the
document picker is backed by the File Provider extension. So this section
verifies that (1) delivers the Document Provider deliverable. See "Document
Provider: why there is no second target" in the plan.

1. Open **Pages** → Browse / Open.
2. **Expected:** "Neutrino Drive" appears as a location alongside iCloud Drive.
3. Navigate into a folder and open a document.
4. **Expected:** it opens, correctly decrypted.
5. In Pages, **Export / Send a Copy → Save to Files → Neutrino Drive → a
   subfolder**.
6. **Expected:** the folder picker offers subfolders, not just the top level.
   (This is `NSExtensionFileProviderSupportsPickingFolders`; without it the save
   resolves only to the root.)
7. **Expected:** the exported file appears in the app **and opens in the web
   app** — again proving it was encrypted on the way in.
8. Repeat with **Word** or **Excel**, and with one third-party app of your
   choice. Different apps drive the picker differently.

---

## 3. Open In Place

The point of this section is a **destructive** failure mode, so run it with a
file you would mind losing — that is the only way to see the bug if it exists.

### 3.1 The file that must survive

1. Put a valid Neutrino key `.json` in **iCloud Drive**. Note it is there.
2. From the Files app, tap it → Share → **Neutrino Drive** (or use "Open In").
3. **Expected:** "Encryption key vN imported successfully."
4. **Expected — THE CRITICAL ASSERTION:** go back to iCloud Drive. **The file is
   still there.**
5. If it is gone, stop. The old `onOpenURL` deleted the incoming file
   unconditionally, which was harmless while
   `LSSupportsOpeningDocumentsInPlace` was `false` and destroys a user's own
   document now that it is `true`. That regression must block this branch.
6. Repeat from a **third-party** storage provider (Dropbox, Google Drive) if
   available — a different provider exercises a different security-scoped URL.

### 3.2 Inbox copies are still cleaned up

1. Import a key from a source that hands over a copy — e.g. an email attachment.
2. **Expected:** the import succeeds.
3. Check the app container's `Documents/Inbox` (via Xcode → Devices → download
   container, or a debug build).
4. **Expected:** the copy has been removed. Leaving Inbox copies behind would
   accumulate key material in the container indefinitely.

### 3.3 Regression — the existing key-import flows

1. Import a key via the in-app file picker. Confirm it still works.
2. Import a key via **QR scan**. Confirm it still works.
3. Confirm Settings → Encryption Key reads "Imported ✓" after each.

---

## 4. Spotlight Search

### 4.1 Off by default — the assertion that matters most

1. **Fresh install** (delete the app first; this cannot be checked on an upgrade).
   Sign in, import keys, browse some files.
2. Swipe down on the home screen and search for a distinctive **file name**.
3. **Expected:** **no Neutrino Drive results.** Indexing is off until the user
   opts in.
4. Open Settings → Search → Spotlight Indexing.
5. **Expected:** the toggle is **Off**, and the copy states plainly that the
   search index is not end-to-end encrypted and is included in device backups.

### 4.2 Opting in

1. Turn **Index File Names** on. Browse a few folders in the app so items index.
2. Search the home screen for a file name.
3. **Expected:** the file appears as a result, with its name and icon.
4. **Expected:** the result shows **no content preview, no snippet of the
   document's text, and no thumbnail of its contents.** Any of those would mean
   decrypted content reached the system index — stop and treat it as a security
   defect, not a UI issue.
5. Tap the result.
6. **Expected:** the app opens to that item.

### 4.3 Opting back out

1. Turn the toggle **off**.
2. Search the same file name from the home screen.
3. **Expected:** the results are gone. An index that outlives the setting makes
   the toggle a lie.
4. Turn it on again, then use **Remove Indexed Names**, and confirm the same.

### 4.4 Logout de-indexes

1. Turn indexing on, browse to populate the index, confirm results appear.
2. **Sign out.**
3. Search the same names.
4. **Expected:** no results. A signed-out device answering system searches with
   the previous user's file names would be a straightforward privacy failure,
   and matters most on a shared or handed-on device.

### 4.5 The honesty check on the copy

1. With the Spotlight toggle **off**, use the **Files app's own search** and
   search for a Neutrino file name.
2. **Expected:** the Files app can find it — because File Provider items are
   visible to the system regardless of our setting.
3. Re-read the Settings footer.
4. **Expected:** it says exactly that. If the copy implies filenames stay private
   while (1) is enabled, the copy is wrong and must be fixed — a privacy control
   that overstates its reach is worse than no control, because it gets trusted.

---

## 5. Regression — nothing else moved

`DownloadService`'s pipeline moved into `E2EEDownloader`. Unit tests cover it,
but confirm the real paths:

1. Download and open a file in the app. Confirm the progress bar advances and
   the file opens.
2. Open a **historical version** from Version History (Phase 5) — it goes through
   the same extracted code.
3. Make a file **available offline**, then open it in Airplane Mode.
4. **Share a file into the app from Photos** (the share extension). Confirm it
   uploads and opens in the web app.
5. Confirm **photo auto-sync** still uploads.
6. Confirm sharing, favorites, and search (Phase 5) are unaffected.

---

## 6. Feature flags

1. `FeatureFlags.filesAppIntegration = false`, rebuild, reinstall.
   **Expected:** no Neutrino Drive location in Files or in any document picker.
   The `.appex` is still in the bundle — that is a bundle property, not a runtime
   one — but with no domain registered nothing invokes it.
2. `FeatureFlags.spotlightSearch = false`, rebuild.
   **Expected:** no Search section in Settings, and no indexing under any
   interaction even if the user setting was previously on.
3. `LSSupportsOpeningDocumentsInPlace` back to `false` in `project.yml`, rebuild.
   **Expected:** key import from iCloud Drive still works (via an Inbox copy),
   and §3.1 still leaves the original in place.
4. Set all three off and confirm the app behaves as the parent branch does.

---

## Expected Results

- **Neutrino Drive appears in the Files app, enumerates the real drive, and opens
  a file correctly decrypted.** Everything else here is secondary to that.
- A file saved into Neutrino Drive from Pages or the Files app arrives
  **encrypted** — verified by opening it in the web app.
- A file larger than 64 MB fails with a readable message rather than crashing the
  extension.
- Deleting from the Files app trashes rather than destroys.
- Remote changes appear on re-enumeration only, and that is understood and
  accepted rather than filed as a bug.
- **A key file imported from iCloud Drive is still in iCloud Drive afterwards.**
- Spotlight indexes nothing until the user opts in, indexes only names when they
  do, and removes everything on opt-out or logout.
- The Settings copy does not overstate what the Spotlight toggle protects.
- Download, offline, share-extension, photo-sync, sharing, versions, and
  favorites are unchanged by the `E2EEDownloader` extraction.
</content>
