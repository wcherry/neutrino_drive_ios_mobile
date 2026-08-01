For Neutrino Drive on iOS, I would not try to build a full Dropbox-style sync client initially. Apple’s sandboxing and background execution restrictions make continuous filesystem synchronization much harder than on macOS.

Instead, I would position the iOS app as:

A secure mobile file browser, document viewer, uploader, and offline access client for Neutrino Drive.

This aligns with how users actually interact with cloud storage on phones and tablets.

> Progress legend: ✅ = done, ⬜ = not yet done. A section header is checked only once every item beneath it is checked.

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

## Epic 5: Upload Files — ⬜

Use:

✅ UIDocumentPicker
✅ Photos Picker
✅ Camera

⸻

Supported Sources

✅ Files app
✅ Photos
✅ Camera
⬜ Share Sheet (no Share Extension target exists yet)

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

## Epic 7: File Viewers — ⬜

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
⬜ AVFoundation (not used directly — QuickLook handles audio/video playback internally)

Deliverables

✅ Most files can be viewed without leaving app.

⸻

## Epic 8: Offline Files — ⬜

⬜ User chooses: "Make Available Offline"

App:

⬜ Downloads encrypted file
⬜ Stores locally
⬜ Maintains decrypted cache

Deliverables

⬜ Offline access works. *(The "Offline" tab currently exists only as a placeholder screen — see `OfflineView.swift`.)*

⸻

## Epic 9: Search — ⬜

Search:

⬜ File names
⬜ Folder names

(Server-side metadata search only. No content search initially — not yet started.)

Deliverables

⬜ Users can locate files quickly.

⸻

## Epic 10: Settings — ⬜

Features

⬜ Storage usage
⬜ Cache size
✅ Key status
✅ Logout
⬜ Sync status

Deliverables

⬜ Basic administration. *(Settings currently covers key import/removal status and sign-out only.)*

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
⬜ Mark files offline
⬜ Search filenames
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

### Push Notifications — ⬜

Notify:

⬜ Shared files
⬜ Upload completion
⬜ Storage limits

Deliverables

⬜ Better engagement.

⸻

Phase 3 — iOS Ecosystem Integration — ⬜

This is where Neutrino begins feeling like a first-class iOS storage provider.

⸻

### Files App Integration — ⬜

⬜ Implement File Provider Extension

This is the equivalent of Dropbox and Google Drive integration.

Users see:

Files App
 └─ Neutrino Drive

Deliverables

⬜ Files accessible system-wide.

⸻

### Document Provider — ⬜

Allows:

⬜ Pages
⬜ Numbers
⬜ Word
⬜ Excel
⬜ Third-party apps

To open Neutrino files directly.

Deliverables

⬜ Deep platform integration.

⸻

### Open In Place — ⬜

⬜ Files can remain in Neutrino Drive without copying. *(`LSSupportsOpeningDocumentsInPlace` is explicitly set to `false` today.)*

Deliverables

⬜ Better storage efficiency.

⸻

### Spotlight Search — ⬜

⬜ Index metadata.

Search:

⬜ File names
⬜ Folder names
⬜ Recent documents

Deliverables

⬜ System-wide search support.

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

### Device Registration — ⬜

⬜ Each device gets a Device Key Pair (iPhone / iPad / MacBook / Browser)
⬜ Account key wrapped separately for each device.

Deliverables

⬜ Foundation for multi-device E2EE.

⸻

### Key Rotation — ⬜

Support:

⬜ Key v1
⬜ Key v2
⬜ Key v3
⬜ Allow decrypting historical documents.

Deliverables

⬜ Future-proof security. *(Only a single active key version is currently stored/supported.)*

⸻

Phase 5 — Advanced Drive Features — ⬜

⸻

### Sharing — ⬜

Support:

⬜ User sharing
⬜ Public links
⬜ Team folders

Using wrapped file keys.

⸻

### Version History — ⬜

View:

⬜ Previous versions
⬜ Restore versions

Reuse existing Drive APIs.

⸻

### Favorites — ⬜

⬜ Star important files.

⸻

### Smart Offline Sync — ⬜

Automatically cache:

⬜ Recent files
⬜ Frequently accessed files

⸻

### Large File Streaming — ⬜

Stream:

⬜ Video
⬜ Audio

Without full download.

⸻

Phase 6 — iPad Productivity Features — ⬜

Once the iPhone experience is mature.

*(A basic adaptive iPad split-view layout already exists in `FilesView`, but none of the advanced productivity features below are implemented.)*

⸻

### Multi-Window Support — ⬜

⬜ Open multiple documents.

⸻

### Drag and Drop — ⬜

Between:

⬜ Neutrino
⬜ Files
⬜ Mail
⬜ Notes

⸻

### Stage Manager Support — ⬜

⬜ Optimized for modern iPad workflows.

⸻

### Apple Pencil Features — ⬜

Future integration with:

⬜ Notes
⬜ PDFs
⬜ Annotation workflows

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
9. ⬜ Offline files
10. ⬜ Basic search
11. ⬜ Settings *(basic version exists; storage usage, cache size, and sync status are still pending)*

I would intentionally postpone Files App integration, File Provider extensions, QR pairing, sharing, version history, and automatic photo backup until after the core encrypted file access experience is proven. The MVP should validate that users can securely access and manage their Neutrino Drive data on iPhone and iPad while keeping the implementation small and focused.
