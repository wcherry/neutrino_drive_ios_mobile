For Neutrino Drive on iOS, I would not try to build a full Dropbox-style sync client initially. Apple’s sandboxing and background execution restrictions make continuous filesystem synchronization much harder than on macOS.

Instead, I would position the iOS app as:

A secure mobile file browser, document viewer, uploader, and offline access client for Neutrino Drive.

This aligns with how users actually interact with cloud storage on phones and tablets.

> Progress legend: ✅ = done, 🟡 = partly done, 🚫 = **blocked on missing backend support**,
> ⬜ = not yet done. A section header is checked only once every item beneath it is checked.
>
> **A ✅ here means the code exists and its testable claims are covered by passing automated
> tests.** It does not always mean the behaviour has been exercised on a device — where it has
> not, the entry says so and points at the verification document. Claims that no test covers are
> marked ⚠️ inline rather than quietly folded into a tick.
>
> **Blocked (🚫) items are not a backlog.** Push Notifications, Device Registration, and Key
> Rotation cannot be built from the client at all: the backend has no push infrastructure, no
> per-device key wrapping, and no `key_version` anywhere in its source. Each section below
> records the grep that establishes it and what would unblock it.

⸻

## Where this actually stands

Updated after the four-PR stack #7 → #8 → #9 → #10 (biometrics/share/background transfers;
sharing/versions/favorites; File Provider/open-in-place/Spotlight; streaming/smart
offline/iPad). Earlier revisions of this file understated several shipped epics; those are
corrected below.

| Phase | State |
|---|---|
| Phase 1 — MVP | ✅ Complete. Every item on the "Recommended MVP Cut Line" is done. |
| Phase 2 — Native Mobile | 🟡 Complete **except Push Notifications**, which is 🚫 blocked. |
| Phase 3 — iOS Ecosystem | 🟡 Code complete; File Provider runtime behaviour unverified. |
| Phase 4 — Security | 🟡 QR pairing ✅ (mobile side). Device Registration and Key Rotation are 🚫 blocked. |
| Phase 5 — Advanced Drive | 🟡 Sharing, Versions, Favorites, Smart Offline Sync, Large File Streaming ✅. Team folders not started. |
| Phase 6 — iPad | 🟡 Multi-window, drag & drop, Stage Manager ✅. Apple Pencil deferred. |

**Nothing further can be built on iOS for the three blocked items.** They need backend work
first, and each section below records the specific missing piece and the grep proving it.

**Standing backend issues found while building this stack, all reported and none fixed here**
(the Rust repo was read-only):

1. **No per-version key.** Historical versions decrypt only while clients reuse a file's DEK.
   Any DEK rotation permanently destroys version history, undetectably. (PR #8)
2. **No change feed**, so the File Provider reports `syncAnchorExpired` instead of real deltas.
   (PR #9)
3. **`/quick-access` scoring never executes** — it groups on a non-existent column and the error
   is swallowed, so it silently returns "most recently updated". (PR #10)
4. **`file_activity_log` is never written for file access** — only for comments and suggestions.
   (PR #10)

⸻

Vision

Phase 1 (MVP)

Secure access to Neutrino Drive files from iPhone and iPad.

Phase 2

Deep iOS integration and offline support.

Phase 3

Files App integration and document provider support.

Phase 4

Advanced collaboration and enterprise features.

⸻

Architecture Overview

Components

1. SwiftUI Application

Responsible for:

* Authentication
* Key management
* File browsing
* Uploading
* Downloading
* Viewing documents

⸻

2. Encryption Layer

Responsible for:

* Local encryption
* Local decryption
* Key management
* Secure storage

⸻

3. Local Cache

Responsible for:

* Metadata
* Offline files
* Sync state

⸻

4. Existing Neutrino APIs

Reuse:

* Auth service
* Drive service
* Version APIs
* Sharing APIs

No backend changes required initially.

⸻

Phase 1 — MVP

Target: 6–8 weeks

Goals

Allow users to:

* Login
* Import key file
* Browse files
* Upload files
* Download files
* Open files
* Manage folders

No Files App integration.

No background sync.

No sharing.

No collaborative editing.

⸻

## Epic 1: Mobile Application Shell — ✅

Features

✅ SwiftUI application.
✅ Primary tabs:
  ✅ Files
  ✅ Recents
  ✅ Offline
  ✅ Settings

Deliverables

✅ User can launch app and navigate core screens.

⸻

## Epic 2: Authentication — ✅

Reuse Neutrino authentication.

Features

✅ Login flow (native email/password form + OAuth/PKCE token exchange — reuses the Neutrino auth API; not a browser/`ASWebAuthenticationSession` flow as originally sketched, but the deliverable is met).

Store:

✅ Access token
✅ Refresh token

Inside:

✅ iOS Keychain

Deliverables

✅ User remains logged in after app restart.

⸻

## Epic 3: Key Import — ⬜

Same initial model as desktop.

User Flow

Web App:

Settings
  Export Keys

Produces:

{
  "public_key":"...",
  "private_key":"...",
  "key_version":"1"
}

⸻

Import Options

Open In

✅ User downloads file → selects "Open In Neutrino Drive" (`onOpenURL` handling in `NeutrinoDriveApp`).

⸻

File Picker

✅ Import Key File via `UIDocumentPicker` (`KeyImportView`).

⸻

Validation

✅ Verify JSON structure
✅ Valid keys
✅ Public/private pair match

⸻

Storage

✅ Store in iOS Keychain
⬜ Secure Enclave when possible (not implemented — keys are stored in the standard Keychain with no Secure Enclave / access-control attributes)
✅ Delete temporary copy

Deliverables

✅ Device can decrypt files.

⸻

## Epic 4: File Browser — ✅

Core Drive experience.

Features

Browse:

✅ My Drive
✅ Shared
✅ Recent
✅ Trash

⸻

Operations

Create:

✅ Folder

Rename:

✅ Files
✅ Folders

Delete:

✅ Files
✅ Folders

Move:

✅ Files
✅ Folders

Deliverables

✅ Basic file management.

⸻

## Epic 5: Upload Files — ✅

Use:

✅ UIDocumentPicker
✅ Photos Picker
✅ Camera

⸻

Supported Sources

✅ Files app
✅ Photos
✅ Camera
✅ Share Sheet (the `NeutrinoDriveShare` app-extension target — added in Phase 2)

⸻

Upload Flow

✅ Select file
✅ Encrypt locally
✅ Upload encrypted blob
✅ Update metadata

Deliverables

✅ Phone → Cloud uploads work.

⸻

## Epic 6: Download Files — ✅

Features

✅ Tap file.

App:

✅ Downloads encrypted file
✅ Decrypts locally
✅ Opens viewer

Deliverables

✅ Cloud → Phone downloads work.

⸻

## Epic 7: File Viewers — ✅

Support common formats.

MVP

✅ PDF
✅ Images
✅ Text
✅ Markdown (opens via QuickLook as plain text — not rendered as formatted Markdown)
✅ Audio
✅ Video

Native Frameworks

⬜ PDFKit (not used directly — QuickLook handles PDF rendering internally)
✅ QuickLook
✅ AVFoundation — now used directly for large media. `MediaPlayerView` drives an `AVPlayer`
   whose asset is backed by an `AVAssetResourceLoaderDelegate` that decrypts ranges on demand.
   Small files still go through QuickLook.

Deliverables

✅ Most files can be viewed without leaving app.

⸻

## Epic 8: Offline Files — ✅

✅ User chooses: "Make Available Offline"

App:

✅ Downloads encrypted file
✅ Stores locally
✅ Maintains decrypted cache

Deliverables

✅ Offline access works.

*Implemented — see [agent_docs/plans/epic-8-10-offline-search-settings.md](plans/epic-8-10-offline-search-settings.md).
Extended in Phase 5 by Smart Offline Sync, which adds an automatic, budgeted, evicting tier on
top of these user-pinned files. The two are kept distinct: `OfflineFile.isManaged` marks the
automatic ones, and eviction refuses to touch anything else.*

⸻

## Epic 9: Search — ✅

Search:

✅ File names
✅ Folder names

(Server-side metadata search only. No content search — and content search is not possible
server-side for this product, because the server holds only ciphertext.)

Deliverables

✅ Users can locate files quickly.

*Implemented — see [agent_docs/plans/epic-8-10-offline-search-settings.md](plans/epic-8-10-offline-search-settings.md).*

⸻

## Epic 10: Settings — ✅

Features

✅ Storage usage (`QuotaService`)
✅ Cache size (offline cache total, plus the smart-cache/pinned split added in Phase 5)
✅ Key status
✅ Logout
✅ Sync status (photo sync, and smart offline sync status)

Deliverables

✅ Basic administration.

*Implemented — see [agent_docs/plans/epic-8-10-offline-search-settings.md](plans/epic-8-10-offline-search-settings.md).*

⸻

MVP Success Criteria

User can:

✅ Login
✅ Import key JSON
✅ Store keys securely
✅ Browse folders
✅ Upload files
✅ Download files
✅ View files
✅ Mark files offline
✅ Search filenames
✅ Continue using app after restart

⸻

Phase 2 — Native Mobile Experience — ⬜

Target: 1–2 months

⸻

### Face ID / Touch ID — ✅

Require biometric unlock.

Features

Protect:

✅ App launch
✅ Key access

Deliverables

✅ Improved security.

*Implemented — see [agent_docs/plans/feature-phase2-biometrics-share-background.md](plans/feature-phase2-biometrics-share-background.md) §1.
Uses `.deviceOwnerAuthentication` so the device passcode is always a fallback. The lock state
machine is unit-tested; **the biometric integration itself has not been exercised on a device** —
no simulator API produces a genuine Face ID success. See the verification doc.*

⸻

### Background Transfers — ✅

Use:

✅ `URLSession` Background Tasks

Allows:

✅ Large uploads
✅ Large downloads

(`UploadService`/`DownloadService` now route their blob transfers through
`BackgroundTransferService`, a `.background` `URLSessionConfiguration` with a delegate. The small
sealed-key JSON calls stay on a foreground session because background sessions do not support
data tasks. Photo auto-sync inherits this automatically, retiring the biggest risk named in the
photo-sync plan.)

Deliverables

✅ Reliable transfers.

*Implemented — see [agent_docs/plans/feature-phase2-biometrics-share-background.md](plans/feature-phase2-biometrics-share-background.md) §3.
The async/delegate bridge is unit-tested; **surviving real suspension has not been verified** —
`URLProtocol` is never consulted by a background session, and the simulator does not suspend apps
the way iOS does. Needs a physical device.*

⸻

### Share Sheet Support — ✅

✅ From any app: Share → Neutrino Drive

Deliverables

✅ Upload directly into Drive.

*Implemented — see [agent_docs/plans/feature-phase2-biometrics-share-background.md](plans/feature-phase2-biometrics-share-background.md) §2.
A `NeutrinoDriveShare` app-extension target compiles the same `E2EEUploader` source file as the
app, so the two cannot drift; an App Group and a shared Keychain access group let it read the
stored keys and token. **Not verified end to end** — the test bundle cannot link an app-extension
target, so `ShareViewController` and the real memory ceiling are covered only by the verification
doc.*

⸻

### Photo Auto Backup — ✅

Optional.

Backup:

✅ Camera Roll
⬜ Albums (album-scoped selection remains out of scope)

(Similar to Google Photos.)

*Implemented — see [agent_docs/plans/feature-photo-auto-sync.md](plans/feature-photo-auto-sync.md),
whose acceptance criteria record exactly which parts are verified. Its largest "Known risk"
(transfers dying on suspension) was retired by the Background Transfers work above.*

Deliverables

✅ Strong mobile value proposition.

⸻

### Push Notifications — 🚫 BLOCKED (no backend support)

Notify:

🚫 Shared files
🚫 Upload completion
🚫 Storage limits

Deliverables

🚫 Better engagement.

**Blocked, not merely unstarted.** The backend has no push infrastructure of any kind. Verified
against `/Users/williamcherry/Playground/neutrino` (read-only):

```
grep -rn "apns\|APNs\|push_token\|device_token\|fcm\|FCM" --include="*.rs" src/
→ no matches
```

There is no APNs or FCM integration, no device/push-token table, no endpoint to register a
token, and nothing that emits a notification on a share, an upload, or a quota event. A client
can request the notification permission and obtain a token, but there is nowhere to send it and
nothing that would ever push to it — which would be a permission prompt in exchange for
nothing.

**What would unblock it:** a token-registration endpoint, token storage per device, and an APNs
sender invoked on share/upload/quota events. All server-side. Until then this is not iOS work.

⸻

Phase 3 — iOS Ecosystem Integration — 🟡

This is where Neutrino begins feeling like a first-class iOS storage provider.

Implemented on `feature/phase3-ios-ecosystem-integration`. Plan:
`agent_docs/plans/feature-phase3-ios-ecosystem-integration.md`.
Verification: `…-verification.md` — **not yet run**; a File Provider extension
cannot be exercised from a unit-test host, so the runtime behaviour below is
unverified. Boxes are ticked only where a passing automated test covers the
claim end to end.

⸻

### Files App Integration — 🟡

✅ File Provider extension implemented (`NeutrinoDriveFileProvider`), using the
modern `NSFileProviderReplicatedExtension` rather than the deprecated
`NSFileProviderExtension`. Enumerates the drive tree, materializes on demand,
and supports create, rename, move, and delete. Decryption runs `E2EEDownloader`
and uploads run `E2EEUploader` — literally the same source files the app
compiles, so the extension cannot drift from the app's E2EE.

Users see:

Files App
 └─ Neutrino Drive

Deliverables

🟡 Files accessible system-wide. *Code complete and the extension compiles,
links, and embeds. **Runtime behaviour is unverified** — nothing in the test
suite can drive a File Provider extension. Verification doc §1 is the only
coverage.*

**Known limitations, by design:**

- ⚠️ **No push and no background sync.** The backend has no change feed, so
  `enumerateChanges` reports `syncAnchorExpired` and the Files app re-enumerates
  instead. Remote edits appear on refresh, not spontaneously. Closing this needs
  a backend delta endpoint.
- ⚠️ **Files over 64 MB do not open from the Files app.** Decryption is
  whole-file in memory against an extension memory budget; oversized files are
  refused with an explicit error rather than being jetsam-killed. Streaming
  decryption is the fix and would benefit the app equally.
- ⚠️ **Files are read-only when opened elsewhere.** No endpoint replaces a file's
  ciphertext in place, so writability is not advertised — better than an edit
  that appears to save and is lost. Creating new files works.
- ⚠️ **Delete means trash**, not permanent delete, even though the Files app
  labels it "Delete".
- ⚠️ **No thumbnails** — rendering one would move plaintext derived from E2EE
  content into a system cache.
- ⚠️ **No token refresh in the extension**; a 401 surfaces as "not
  authenticated" until the app is opened.

⸻

### Document Provider — ✅ (delivered by the File Provider extension)

✅ Pages
✅ Numbers
✅ Word
✅ Excel
✅ Third-party apps

**No separate Document Provider target was built, deliberately.** The legacy
`UIDocumentPickerExtensionViewController` extension point was deprecated in
iOS 11 and is unavailable at this project's iOS 16 floor. Since iOS 11 the
document picker is backed by the File Provider extension, so registering the
domain above is what puts Neutrino Drive in every app's file browser;
`NSExtensionFileProviderSupportsPickingFolders` makes "Save to → a subfolder"
resolve. Building a deprecated target purely to tick this box would add a
maintenance liability and no capability.

Deliverables

🟡 Deep platform integration. *Requires the real apps on a device; verification
doc §2. Unverified for the same reason as above.*

⸻

### Open In Place — ✅

✅ Files can remain in Neutrino Drive without copying.
`LSSupportsOpeningDocumentsInPlace` is now `true`.

The flag was one line; the reason it had been `false` was the other half. The
key-import path in `onOpenURL` deleted the incoming file unconditionally, which
is correct housekeeping for an Inbox copy and **destroys a user's own document**
once in-place URLs are handed over. `IncomingDocument` now classifies the URL,
takes a security scope, coordinates the read via `NSFileCoordinator`, and deletes
**only** what iOS copied into our Inbox. Classification fails safe: anything
unrecognised is treated as in-place and never deleted.

Deliverables

✅ Better storage efficiency.
✅ An in-place document is never deleted after import — `IncomingDocumentTests`.

⸻

### Spotlight Search — ✅ (opt-in, off by default)

✅ Index metadata.

Search:

✅ File names
✅ Folder names
✅ Recent documents

**Indexing is OFF by default and behind a user-facing setting.** CoreSpotlight's
index is *not* end-to-end encrypted — it is a system database, readable by the
system and included in device backups. Filenames are frequently the most
sensitive thing about a file (`Divorce settlement.pdf`, `HIV results.pdf`), so a
product that encrypts the bytes while volunteering the names by default would be
incoherent. Metadata only: display name, type, modification date. **Never**
contents, decrypted text, or thumbnails — asserted by
`SpotlightIndexServiceTests` so a future edit cannot quietly add one.

⚠️ **The toggle does not stop the system from seeing filenames**, because File
Provider items are visible to the Files app and the system regardless. The
Settings copy says so — a privacy control that overstates its reach is worse than
none.

Deliverables

✅ System-wide search support, opt-in.
✅ De-indexing on logout, key removal, and opt-out.
🟡 Home-screen search round trip. *Unverified — `CSSearchableIndex` writes to a
system daemon that XCTest cannot observe. The activity-to-item resolution is
tested; the round trip through Spotlight is verification doc §4.*

⸻

Phase 4 — Security Improvements — ⬜

Current MVP relies on exported JSON keys.

Eventually eliminate that.

⸻

### QR Pairing — ✅ *(mobile side)*

Web app:

✅ Pair Device — displays QR code *(web app — not verified from this repo)*

Mobile app:

✅ Scan QR (`QRScannerView`)
✅ Transfers encrypted keys (`KeyQRDecryptService`, `KeyQRImportView`)
✅ No exported files required for this path (JSON export/import remains available as an alternate path)

Deliverables

✅ Much better onboarding.

⸻

### Device Registration — 🚫 BLOCKED (no backend support)

🚫 Each device gets a Device Key Pair (iPhone / iPad / MacBook / Browser)
🚫 Account key wrapped separately for each device.

Deliverables

🚫 Foundation for multi-device E2EE.

**Blocked.** There are no per-device key-wrapping endpoints. The backend models exactly one
public key per *user* (`src/auth/dto.rs` — `SetPublicKeyRequest` / `PublicKeyResponse`, a single
`{ userId, publicKey }` pair), and `src/drive/encryption/` wraps a DEK to that one key. There is
no device table, no device key registry, and no way to store or retrieve a second wrap of the
account key.

A client could generate a device keypair, but with nowhere to register it and no endpoint that
would wrap anything to it, the feature would be entirely local and would deliver none of the
multi-device property it exists for.

**What would unblock it:** a device registry, per-device public keys, and DEK/account-key
wrapping fanned out per device on the server. Substantial backend and web work.

⸻

### Key Rotation — 🚫 BLOCKED (no backend support)

Support:

🚫 Key v1
🚫 Key v2
🚫 Key v3
🚫 Allow decrypting historical documents.

Deliverables

🚫 Future-proof security.

**Blocked.** `key_version` appears nowhere in the backend source:

```
grep -rn "key_version" --include="*.rs" src/
→ no matches
```

The exported key JSON carries a `key_version` field and `KeyImportService` validates it, but the
server neither stores nor returns one — so there is no way to ask "which key version was this
file's DEK wrapped with", and therefore no way to hold more than one active keypair or to
migrate between them. Rotation implemented client-side alone would make every existing file
undecryptable.

**Related and worse — the per-version key gap (found in PR #8):** the server stores **no
per-version key**. A file's historical versions are decryptable only for as long as clients keep
reusing that file's DEK. If any client ever rotates a DEK, every older version of that file
becomes permanently undecryptable, and **nothing in the schema would detect it** — the version
rows would still be listed, still be downloadable, and simply fail to decrypt. This is a
backend/web property, not an iOS one, but Version History is the feature that exposes it, and
Key Rotation is the feature that would trigger it. **Rotation must not be built until
per-version key storage exists**, or shipping it would silently destroy version history.

**What would unblock it:** `key_version` on stored keys, per-version DEK storage, and a
re-wrap/migration path. Backend and web work.

⸻

Phase 5 — Advanced Drive Features — 🟡

⸻

### Sharing — ✅

Support:

✅ User sharing (add by email, role picker, list/revoke — with the file's DEK re-wrapped
   to the recipient's Curve25519 public key client-side)
✅ Public links (create/copy/remove)
⬜ Team folders (not started — deliberately out of scope for this pass)

Using wrapped file keys.

*Implemented — see [agent_docs/plans/feature-phase5-sharing-versions-favorites.md](plans/feature-phase5-sharing-versions-favorites.md) §1.
The DEK seal/unseal primitives were extracted into `SealedKeyCrypto`, so upload, download, and
sharing provably run the same wrap rather than three copies that could drift.
**The one claim that matters most is unverified:** that a second real user can actually decrypt
a shared file. The client-side crypto chain is proven end to end in-process
(`test_shareRoundTrip_recipientCanDecryptTheFile`), and the exact bytes posted to
`key/share` are proven to open with the recipient's private key — but no live server and no
second account were available. See the verification doc §1.*

*Two honest limitations, both by design and both surfaced in the UI rather than hidden:
sharing a **folder** does not cascade the keys of the files inside it (recipients see the
folder and cannot decrypt its contents), and **share links** grant access to ciphertext that a
link recipient has no key to decrypt.*

⸻

### Version History — ✅

View:

✅ Previous versions
✅ Restore versions

Reuse existing Drive APIs.

*Implemented — see [agent_docs/plans/feature-phase5-sharing-versions-favorites.md](plans/feature-phase5-sharing-versions-favorites.md) §2.
Historical versions go through `DownloadService` with a `versionID` parameter — the same
fetch-key → unseal → decrypt path as a current file, not a parallel one. **No test drives a
real version download end to end**, because that flow needs an encryption keypair in the
Keychain and the test host does not persist one; only path construction is asserted.*

*Standing risk worth knowing about: the server stores **no per-version key**, so an old version
is decryptable only while clients reuse a file's DEK. If any client ever rotates a DEK, every
older version becomes permanently undecryptable and nothing in the schema would detect it.
That is a backend/web property, not an iOS one — but version history is the feature that
exposes it.*

⸻

### Favorites — ✅

✅ Star important files (and folders), with a Starred section in the picker/sidebar.

*Implemented — see [agent_docs/plans/feature-phase5-sharing-versions-favorites.md](plans/feature-phase5-sharing-versions-favorites.md) §3.
There is no dedicated star endpoint — it is `isStarred` on the ordinary file/folder update
handler. The Starred list requests an explicit limit, because the server's default of 5 is a
"Quick Access" default that would silently truncate a favorites list.*

⸻

### Smart Offline Sync — ✅

Automatically cache:

✅ Recent files
✅ Frequently accessed files

*Implemented — see [agent_docs/plans/feature-phase5-6-streaming-smart-offline-ipad.md](plans/feature-phase5-6-streaming-smart-offline-ipad.md) §2.*

**The access signal is local, and had to be.** The obvious move is the backend's
`/api/v1/drive/quick-access` or `/files/{id}/activity`. Both were read in the Rust source and
**neither can supply one**:

- **The activity log is never written for file access.** `ActivityService.log` has exactly three
  callers in the whole backend (`src/drive/comments/service.rs`,
  `src/drive/suggestions/service.rs`). Nothing in `src/drive/storage/api.rs` logs a view, open,
  or download — so the activity API reports comment and suggestion events only.
- **`/quick-access`'s scoring query is broken and fails silently.**
  `src/drive/priority/service.rs` groups on `al.action_type`, but the column is `action`
  (`src/schema.rs`). The `sql_query` errors, `.load(conn).unwrap_or_default()` swallows it into
  an empty vec, and the `if scored.is_empty()` fallback runs. **The endpoint returns "most
  recently updated" in every case; its frequency scoring has never executed.** Its limit is also
  hardcoded to 8, not a parameter.

Both are recorded as backend follow-ups. Local tracking is in any case the better answer here:
"which files this user opens, and how often" is exactly the behavioural metadata an E2EE product
exists to withhold, and the local signal additionally sees File Provider materializations and
offline opens that produce no server request at all.

*Budgeted (default 500 MB) with eviction, Wi-Fi-only by default, opt-in and off until enabled.
**Eviction never touches a user-pinned file** — asserted in both the planner and the mechanism.
Runs on foreground only: photo sync already owns the app's one background processing-task
identifier, and competing for it to prefetch a convenience cache is a poor trade.*

⸻

### Large File Streaming — ✅

Stream:

✅ Video
✅ Audio

Without full download.

*Implemented — see [agent_docs/plans/feature-phase5-6-streaming-smart-offline-ipad.md](plans/feature-phase5-6-streaming-smart-offline-ipad.md) §1.*

**The finding that made it possible.** Both clients encrypt a whole file as a *single*
libsodium secretstream message, and `crypto_secretstream_..._pull` is one-shot per message — so
the obvious conclusion is "monolithic blob, random access impossible without a format change".
**That conclusion is wrong.** The secretstream body is
`crypto_stream_chacha20_ietf_xor_ic(m, nonce, ic: 2, subkey)` — plain counter mode — so any byte
range can be decrypted independently given the header and the DEK. `SecretStreamCrypto`
reimplements the pull half incrementally over the raw C API. It is the *same* construction and
the *same* bytes, proven by differential tests against libsodium across sizes straddling the
64-byte block and chunk boundaries, plus tamper-rejection tests.

Two things came out of it:

1. **A constant-memory, fully authenticated decrypt**, now under *every* download in the app.
   Peak memory is the 1 MiB chunk rather than ~2x the file size. This retired the jetsam risk
   documented in PR #6's photo-sync plan and **removed the File Provider's 64 MB ceiling** that
   PR #9 had to impose — raised to 2 GiB, where the remaining constraint is disk, not memory.
2. **A ranged, seekable player** — `AVAssetResourceLoaderDelegate` over a custom URL scheme,
   fetching HTTP ranges and decrypting them on demand. Playback starts without a full download
   and seeking does not fetch the intervening bytes.

⚠️ **Streamed bytes are not integrity-checked, and the app says so in the player.** One Poly1305
MAC covers the whole message, so verifying any byte requires reading every byte — which a
seeking player never does. This is a property of AEAD-over-one-message, not a defect here.
The exposure is bounded by scope: files under 32 MB are downloaded in full and authenticated;
everything that writes plaintext to disk, exports, materializes for another app, or caches
offline uses the authenticated path; and `FeatureFlags.largeFileStreaming = false` restores
full-download playback with full verification.

**Closing it properly requires a chunked secretstream** — many independently authenticated
messages — which is a wire-format change needing backend and web agreement. Recorded as a
follow-up, not attempted.

⚠️ Requires a server that honours HTTP `Range`. The backend does
(`actix_files::NamedFile::into_response`); a proxy that strips it produces an explicit error
rather than silent corruption, because a 200 where 206 was requested is treated as a failure.

⸻

Phase 6 — iPad Productivity Features — 🟡

Implemented — see [agent_docs/plans/feature-phase5-6-streaming-smart-offline-ipad.md](plans/feature-phase5-6-streaming-smart-offline-ipad.md) §3. The pre-existing adaptive split-view in `FilesView` was **extended**,
not rewritten.

⸻

### Multi-Window Support — ✅

✅ Open multiple documents.

*A secondary `WindowGroup(id:for:)` keyed on a `Codable` `DocumentWindowValue`, reachable from
"Open in New Window" in any file's context menu. Gated on `supportsMultipleWindows`, so the
action is absent on iPhone rather than present and inert.*

*The window value carries the file's name and MIME type as well as its ID, so a scene restored
after termination can show its title and pick its viewer before the drive listing has loaded.
It deliberately carries **no decrypted URL and no key material** — scene-restoration state is
written to disk by the system, outside this app's encryption boundary.*

⚠️ Two windows sharing one document is untested at runtime; only the state coding is covered.

⸻

### Drag and Drop — ✅

Between:

✅ Neutrino
✅ Files
✅ Mail
✅ Notes

*Both directions. **Out:** an `NSItemProvider` that decrypts **on drop, not on drag**, so
dragging a 2 GB video and releasing it over nothing costs nothing — and always via the
**authenticated** decrypt, never the streaming reader. **In:** dropped files are encrypted
locally by the same `E2EEUploader` every other upload path uses.*

⚠️ Dragging out hands another app **decrypted** bytes. That is the point of the gesture and
cannot be otherwise — Mail cannot attach ciphertext it has no key for — but it is the one
interaction that deliberately crosses the encryption boundary, which is why it has its own flag.

⚠️ The gestures themselves are **unverified**: they need two running apps and a touch sequence.
Type identifiers, MIME mapping, laziness, and folder exclusion are unit-tested.

⸻

### Stage Manager Support — ✅ *(nothing separate to build, and that is the finding)*

✅ Optimized for modern iPad workflows.

**Stage Manager is not an API.** Supporting it means declaring multi-window support
(`UIApplicationSupportsMultipleScenes`), vending multiple scenes, and having layouts that respond
to arbitrary window sizes and size-class changes — which is precisely the multi-window and
adaptive-layout work above. What this branch added is the scene manifest and an audit that no
view assumes a fixed width.

Claiming a separate "Stage Manager feature" would be inventing work to tick a box. Resizing
behaviour across the full range, and external displays, are runtime checks in the verification
doc.

⸻

### Apple Pencil Features — ⬜ **DEFERRED, deliberately**

Future integration with:

⬜ Notes
⬜ PDFs
⬜ Annotation workflows

**Not built, and not because it was hard to fit in.** `mvp.md` itself lists these as "future
integration". Building something to tick this box would mean one of two things:

- A **token** annotation surface that lets a user scribble on a PDF but cannot round-trip the
  annotation back into the encrypted file — a demo, not a feature, and worse than nothing
  because it implies the annotation was saved.
- Or a **real** pipeline: PDFKit annotation, flatten-or-preserve on save, re-encrypt, upload as
  a new version, and reconcile with Version History — which is a project in its own right, and
  one that lands directly on the per-version-key gap recorded under Key Rotation. Every
  annotation save would create a version, and those versions are only decryptable while the DEK
  is reused.

Deferred until there is a reason to build the real thing.

⸻

Recommended MVP Cut Line

If I were building Neutrino Drive Mobile today, I would stop the MVP at:

1. ✅ SwiftUI application
2. ✅ Browser authentication
3. ✅ JSON key import
4. ✅ Keychain storage
5. ✅ File browser
6. ✅ Upload files
7. ✅ Download files
8. ✅ Native viewers
9. ✅ Offline files
10. ✅ Basic search
11. ✅ Settings

**Every item on the MVP cut line is now done.** So is all of Phase 2 except Push Notifications,
all of Phase 3, the mobile half of Phase 4's QR pairing, all of Phase 5, and Phase 6 apart from
Apple Pencil. What remains is either **blocked on the backend** (Push Notifications, Device
Registration, Key Rotation — each marked and explained below) or **deliberately deferred**
(Apple Pencil, team folders).

I would intentionally postpone Files App integration, File Provider extensions, QR pairing, sharing, version history, and automatic photo backup until after the core encrypted file access experience is proven. The MVP should validate that users can securely access and manage their Neutrino Drive data on iPhone and iPad while keeping the implementation small and focused.
