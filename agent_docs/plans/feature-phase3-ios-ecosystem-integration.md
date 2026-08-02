# Implementation Plan: Phase 3 — iOS Ecosystem Integration

## What is changing and why

All four Phase 3 items in `agent_docs/mvp.md` land here: **Files App Integration**
(a File Provider extension), **Document Provider**, **Open In Place**, and
**Spotlight Search**.

One of the four is not built as briefed, and that is a deliberate call rather
than a shortfall — see "Document Provider: why there is no second target".

This branch **stacks on `feature/phase5-sharing-versions-favorites`** (PR #8),
which itself stacks on `feature/phase2-biometrics-share-background` (PR #7). It
is not based on `main`.

**No backend changes.** Every endpoint used here already exists; the route list
was read out of `src/drive/filesystem/api.rs` and `src/drive/storage/api.rs` in
the read-only Rust tree, not inferred. Two shapes matter and are easy to get
wrong:

| Assumption | Actually |
|---|---|
| "`GET /folders/{id}` lists children" | It does, **and** returns the folder itself as `folder: Option<FolderResponse>` (`FolderContentsResponse`, `dto.rs:163`). That is what makes `item(for:)` answerable for a folder without a second endpoint. |
| "moving a file needs the bulk endpoint" | `UpdateFileRequest.folder_id` is `Option<Option<String>>` (`dto.rs:56`) — so `PATCH /files/{id}` with `{"folderId": null}` moves to root, and omitting the key means "no change". A single `PATCH` does rename **and** move, which is exactly the shape `modifyItem` wants. |

**There is no change-feed endpoint.** Nothing in the route list offers a delta,
cursor, or changes-since query. That single fact shapes the whole File Provider
design — see "The sync anchor problem", which is the most important limitation
in this branch.

## Layers affected

- **Backend — none.** Read-only audit of the Rust source only.
- **Service — `DriveAPIClient`** *(new — `Services/DriveAPIClient.swift`)*. A
  plain, non-`@MainActor`, non-`ObservableObject` HTTP client for the drive
  metadata endpoints. The extension-safe counterpart to `DriveService`.
- **Service — `E2EEDownloader`** *(new — `Services/E2EEDownloader.swift`)*. The
  fetch-key → unseal → fetch-blob → decrypt pipeline, **extracted** from
  `DownloadService.download` so the app and the File Provider extension provably
  run the same decrypt. Exactly the `E2EEUploader` move from Phase 2.
- **Service — `DownloadService`** *(modified)*. Keeps its entire public surface
  and its `isDownloading`/`progress`/`error` publishing; delegates the pipeline
  to `E2EEDownloader`.
- **Service — `FileProviderDomainService`** *(new)*. App-side registration and
  removal of the `NSFileProviderDomain`.
- **Service — `SpotlightIndexService`** *(new)*. CoreSpotlight metadata indexing,
  gated by a user setting that is **off by default**.
- **Target — `NeutrinoDriveFileProvider`** *(new app extension)*. The
  `NSFileProviderReplicatedExtension` itself, plus its item, identifier, and
  enumerator types.
- **App — `NeutrinoDriveApp`** *(modified)*. Open-in-place URL handling, Spotlight
  deep-link continuation, domain lifecycle.
- **View — `SettingsView`** *(modified)*, **`SpotlightSettingsView`** *(new)*.
- **Config — `FeatureFlags`** *(modified)*. `filesAppIntegration`, `openInPlace`,
  `spotlightSearch`.
- **Config — `project.yml`** *(modified)*. New target, new shared-source entries,
  and `LSSupportsOpeningDocumentsInPlace` flipped to `true`.
- **Tests** — `DriveAPIClientTests`, `FileProviderItemTests`,
  `FileProviderIdentifierTests`, `SpotlightIndexServiceTests`,
  `IncomingDocumentTests`, additions to `DownloadServiceTests`.

## 1. File Provider extension

### Replicated, not the deprecated class

`NSFileProviderReplicatedExtension` (iOS 16+, and the project's floor is exactly
iOS 16.0). The older `NSFileProviderExtension` is deprecated and its
"placeholder file on disk" model would force the extension to own a mirror of the
whole tree in the App Group container — a second copy of user data, in plaintext,
outside the Keychain-guarded path. Declining that is a security decision as much
as a modernity one.

Replicated extensions have **no implicit default domain**. The containing app
must call `NSFileProviderManager.add(_:)`; nothing appears in the Files app until
it does. `FileProviderDomainService` does that on launch when the user is both
authenticated *and* has imported keys, and calls `remove(_:)` on logout or key
removal. Registering a domain for a signed-out user would put a permanently
failing "Neutrino Drive" location in everybody's Files app.

### Identifier mapping — the collision that would silently corrupt

`NSFileProviderItemIdentifier` is one flat string namespace. Drive file IDs and
folder IDs come from **two different tables** and nothing guarantees they do not
collide. A collision would not fail a build or a request; it would make the Files
app fetch a folder's contents for a file, or delete the wrong row.

So identifiers are prefixed — `f:<id>` for files, `d:<id>` for folders — and the
root maps to `NSFileProviderItemIdentifier.rootContainer` rather than to a Drive
ID (the Drive root has no ID; it is `parentID == nil`). The mapping is a pure
function in `FileProviderItemIdentifier.swift`, which is compiled into the app
target as well as the extension **specifically so it can be unit-tested** — see
"What is actually testable".

### The sync anchor problem

`NSFileProviderReplicatedExtension` wants `enumerateChanges(for:from:)` and
`currentSyncAnchor` — an incremental delta feed. **The backend has none.** There
is no changes endpoint, no cursor, no `updatedSince` query.

Three options were considered:

1. **Fabricate a delta by diffing full enumerations.** Requires the extension to
   persist a snapshot of the entire tree, which is metadata-at-rest outside the
   Keychain and re-introduces the mirror the replicated model exists to avoid.
   Rejected.
2. **Return a constant anchor and never report changes.** The Files app would
   believe it is up to date forever and show stale content indefinitely. This is
   the worst option and is the one that *looks* like it works. Rejected.
3. **Expire the anchor, forcing full re-enumeration.** `currentSyncAnchor`
   returns a timestamp-derived anchor; `enumerateChanges` immediately fails with
   `NSFileProviderError.syncAnchorExpired`, which the system's contract defines
   as "drop your cache and enumerate from scratch".

**(3) is chosen** and it is an honest signal rather than a workaround: the
extension is telling the truth, which is that it cannot describe what changed.
The cost is real and must not be glossed: **there is no push, and no background
sync.** Changes made on the web or another device appear when the Files app
re-enumerates — typically on navigating into a folder or pulling to refresh — not
spontaneously. A Dropbox-grade experience needs a backend change feed, and that
is a backend work item, not something the client can paper over.

### Materialization and the memory ceiling

`fetchContents` runs `E2EEDownloader` — the same code the app runs — and hands
back a decrypted plaintext file. The Keychain read works because the extension
carries the same shared access group as the share extension.

The hard constraint is that `E2EEDownloader` decrypts **whole-file in memory**:
`secretStream` is opened over one `[24-byte header][ciphertext]` buffer and
pulled in a single call. In the app that is merely wasteful. In a File Provider
extension, whose memory budget is a small fraction of an app's, it is fatal — and
the failure mode is a jetsam kill, which the Files app surfaces as an
uninformative generic error with no indication that file size was the cause.

So the extension **refuses files above `FileProviderLimits.maxMaterializableBytes`
(64 MB) with a clear error** instead of attempting them. That is a real
functional gap versus the app, stated plainly: large files browse and appear in
the Files app but will not open there. The fix is streaming decryption, which is
a separate piece of work already flagged as a follow-up in
`feature-photo-auto-sync.md`, and it would benefit the app equally.

### Mutations

`createItem`, `modifyItem`, and `deleteItem` are **required** members of
`NSFileProviderReplicatedExtension` — there is no partial conformance. Each is
mapped onto an operation that already exists:

| File Provider operation | Drive call |
|---|---|
| create folder | `POST /api/v1/drive/folders` |
| create file (with contents) | `E2EEUploader.upload` — the identical encrypt-and-POST the app and share extension use |
| rename and/or move | one `PATCH /api/v1/drive/files/{id}` or `/folders/{id}` |
| delete | `POST /api/v1/drive/bulk/trash` (**trash, not permanent** — see below) |

**Delete means trash.** The Files app's affordance says "Delete" and the user
will read it as destructive, but routing it to the permanent-delete endpoint
would let a mis-swipe in a system UI destroy an E2EE file that cannot be
recovered from a backup the server cannot read. Trash is recoverable and matches
what the in-app delete does.

**Files created from the Files app are encrypted.** They go through
`E2EEUploader`, so a document saved into Neutrino Drive from Pages is sealed with
the user's DEK exactly as an in-app upload is. Anything less would be a silent
plaintext hole punched through the product's central promise.

## 2. Document Provider: why there is no second target

The brief allows for this and it is the correct outcome: **a separate Document
Provider target would be a deprecated, redundant target built only to tick a
box, and it is not created.**

The legacy Document Provider — `UIDocumentPickerExtensionViewController` plus the
`com.apple.fileprovider-ui` extension point — was deprecated in iOS 11 and is
unavailable to a project whose floor is iOS 16. Since iOS 11 the document picker
is backed by the File Provider extension: `UIDocumentPickerViewController`,
Pages' "Browse", Word's "Open", and every third-party app's file picker all
enumerate File Provider domains. Registering the domain in (1) is what puts
Neutrino Drive in those pickers.

So Phase 3's Document Provider deliverable is **delivered by the File Provider
extension**, and the mvp.md entry is updated to say so rather than to claim a
component that does not exist. The one thing that does need declaring is the
extension's willingness to vend folders as pick targets
(`NSExtensionFileProviderSupportsPickingFolders`), so "Save to → Neutrino Drive →
some folder" resolves.

## 3. Open In Place

`LSSupportsOpeningDocumentsInPlace` flips `false` → `true`. Flipping the flag is
one line; the reason it was not already `true` is the second half.

### The bug the flag would have created

`RootContentView.onOpenURL` currently does this:

```swift
let data = try Data(contentsOf: url)
let bundle = try KeyImportService.importKey(from: data)
KeyImportService.storeKeys(bundle)
try? FileManager.default.removeItem(at: url)   // ← here
```

With the flag `false`, iOS copies every incoming document into
`<Documents>/Inbox/` and hands over the copy, so deleting it is correct
housekeeping. With the flag `true`, the URL handed over can be **the user's
actual file**, still living in iCloud Drive or another provider. That line would
then delete a user's document out of their own storage as a side effect of
importing a key from it. Silent, unrecoverable, and caused entirely by turning on
an unrelated flag.

Two further things break at `true`: the URL is security-scoped and
`Data(contentsOf:)` fails without `startAccessingSecurityScopedResource()`, and
reading a file another process may be writing requires `NSFileCoordinator`.

### The fix

A new `IncomingDocument` type owns all three concerns:

- **Classification.** `IncomingDocument.classify(url:)` returns `.inboxCopy` when
  the URL is inside this app's `Documents/Inbox`, `.inPlace` otherwise. SwiftUI's
  `onOpenURL` discards the `UIOpenURLContext.options.openInPlace` flag that would
  answer this directly, so containment in our own Inbox is the available signal —
  and it is the *safe* default, because anything unrecognised is treated as
  in-place and therefore never deleted.
- **Access.** `startAccessingSecurityScopedResource()` with a balanced `stop` in
  `defer`, and a coordinated `NSFileCoordinator` read.
- **Deletion.** Only `.inboxCopy` is removed. An in-place document is read and
  left exactly where it was.

The key-import flow keeps working in both cases; the difference is only whether
the source file survives, and it now survives whenever it belongs to the user.

## 4. Spotlight Search — and the decision not to index by default

This is an end-to-end-encrypted product and CoreSpotlight's index is **not**
encrypted end to end. It is a system database, readable by the system, included
in device backups, and used to serve results to Siri Suggestions and system-wide
search surfaces. Anything put into it has left the E2EE boundary.

### What is indexed

Metadata only, and a deliberately narrow slice of it: `displayName` (the file or
folder name), `contentType`, `contentModificationDate`, and a `domainIdentifier`
used for bulk removal. **Never** file contents, never decrypted plaintext, never
a thumbnail rendered from decrypted bytes, never `textContent`. `CSSearchableItem`
offers fields that would happily accept a document's text; none of them are
populated.

### The default is OFF, and here is why

The obvious reading is "filenames are just metadata, index them". That is wrong
for this product. Filenames are frequently the most sensitive thing about a file
— `Divorce settlement.pdf`, `HIV results.pdf`, `Layoff list Q3.xlsx`, a client's
name — and a threat model that goes to the trouble of encrypting the bytes while
volunteering the names to a system index is incoherent. A user who chose an E2EE
drive did not implicitly consent to that.

So `FeatureFlags.spotlightSearch` gates the code, and a separate user-facing
setting — `SpotlightIndexService.isEnabled`, **default `false`** — gates whether
a single item is ever written. The Settings toggle states in plain language that
the index is not end-to-end encrypted and that filenames become visible to the
system and to device backups. Turning the toggle off de-indexes everything
already written.

### The caveat that keeps this honest

**Enabling the File Provider extension exposes filenames to the system anyway,
and the Spotlight toggle does not prevent it.** Items vended through an
`NSFileProviderItem` are displayed and searched by the Files app, and the system
indexes materialized items under its own policy. The toggle governs *our*
`CSSearchableIndex` writes and nothing more.

Presenting the toggle as "filenames stay private" would therefore be false once
(1) ships. The Settings copy says what is true: this controls Neutrino's own
indexing, and files browsed in the Files app are visible to the system
regardless. A privacy control that overstates its reach is worse than none,
because it is trusted.

### Deep linking and teardown

A Spotlight result carries `CSSearchableItemActionType`; the app resolves
`CSSearchableItemActivityIdentifier` back to a Drive ID and navigates.
De-indexing happens on logout, on key removal, and on toggling the setting off —
via `deleteSearchableItems(withDomainIdentifiers:)`, so one call clears
everything regardless of what was written or when.

## Code-sharing strategy

Unchanged from Phase 2 (`feature-phase2-biometrics-share-background.md`,
"Code-sharing strategy"): individual source files are listed in **both** targets
rather than moved into a framework, so the extension compiles literally the same
file. The property that matters here — "the extension decrypts exactly the way
the app decrypts" — is guaranteed by file identity more strongly than by any API
contract.

That constraint is what forces `E2EEDownloader` and `DriveAPIClient` to exist.
`DownloadService` is `@MainActor` + `ObservableObject`; `DriveService` drags in
`AuthService` and the published-collection object graph. Neither belongs in a
memory-constrained extension, and neither can be imported without pulling most of
the app in behind it.

Files added to the File Provider target's source list: `FeatureFlags.swift`,
`SharedStorage.swift`, `KeychainService.swift`, `SealedKeyCrypto.swift`,
`E2EEUploader.swift`, `E2EEDownloader.swift`, `DriveAPIClient.swift`,
`BackgroundTransferService.swift`, and the four File Provider sources. Notably
absent, as before: `AuthService`, `DriveService`, and everything in `Views/`.

**The extension does not refresh tokens.** `AuthService` is not compiled into it,
so it reads the access token from the shared Keychain and fails cleanly with
`NSFileProviderError.notAuthenticated` on a 401. Re-authentication happens in the
app, and the Files app's own "sign in" affordance points there. Duplicating
refresh logic into a second process racing the first over one refresh token would
be a materially worse outcome than a clear error.

### The background-session trap

`BackgroundTransferService` documents "one session per identifier per process".
The File Provider extension is a **separate process**, and constructing a second
`.background` session with `com.neutrino.drive.transfers` there is undefined
behaviour. The extension therefore always builds its `E2EEDownloader` over a
`.foreground` session (`BackgroundTransferService(session:)`, the mode already
used by tests and the `backgroundTransfers` kill switch). It is also the right
call on its own terms: an extension is torn down as soon as its operation
completes, so it has nothing to hand a background transfer to.

## Feature flags

```swift
static let filesAppIntegration: Bool = true  // File Provider domain registration
static let openInPlace: Bool = true          // in-place document handling
static let spotlightSearch: Bool = true      // CoreSpotlight indexing (user setting still off)
```

`filesAppIntegration == false` means no domain is ever registered, so the
location does not appear in the Files app. The extension is still present in the
bundle — an extension's presence is a bundle property, not a runtime one, the
same caveat already recorded for `shareExtension` — but with no domain it is
never invoked.

`spotlightSearch == false` means no index write, no de-index, and the Settings
section is hidden. Note the two-level gate: the build flag being `true` does
**not** enable indexing, because the user setting is independently `false` until
someone turns it on.

## What is actually testable — and what is not

This has to be said before the acceptance criteria, because the honest answer is
uncomfortable.

**A File Provider extension cannot be exercised from a unit-test host.** It is
loaded by `fileproviderd` in response to a registered domain, against a real
Files app, in its own process, with its own entitlements. XCTest's host app
cannot instantiate `NSFileProviderReplicatedExtension` and drive it; there is no
in-process harness, and the protocol's completion-handler surface is invoked by
the system, not by callers. Nothing in `NeutrinoDriveTests/` proves that the
extension enumerates, materializes, or uploads anything.

What *is* provable, and what the tests here actually cover, is the pure logic
that would otherwise be silently wrong inside that untestable shell. This is why
the identifier mapping, item construction, capability computation, and size
guard are deliberately factored out into files compiled into **both** targets:

- identifier ⇄ Drive ID round-tripping, including the file/folder collision case
- `FileProviderItem` construction from the real API DTOs — filename, parent,
  content type, size, capabilities
- the materialization size guard's threshold behaviour
- `DriveAPIClient`'s requests and decoding, via `MockURLProtocol`
- `IncomingDocument.classify` for in-place vs Inbox-copy
- `SpotlightIndexService`'s default-off behaviour and its attribute set —
  specifically, that no content-bearing field is ever populated

The compile of the extension target *is* verified: `xcodebuild` builds it as an
embedded dependency of the app. That catches the failure mode Phase 5 could not
catch for the share extension (a missing `project.yml` source entry breaks the
extension build alone). It proves the code compiles and links. It proves nothing
about behaviour.

Everything else is `feature-phase3-ios-ecosystem-integration-verification.md`,
and that document has not been run — no device and no live server were available.

## Known gaps / risks

- **No change feed, therefore no push and no background sync.** The headline
  limitation. Remote changes surface on re-enumeration only. Fixing it properly
  requires a backend delta endpoint.
- **Files larger than 64 MB do not open from the Files app.** Whole-file
  in-memory decryption against an extension memory budget. They browse and are
  listed; materialization is refused with an explicit error rather than a jetsam
  kill. Streaming decryption is the fix and is out of scope.
- **The extension cannot refresh an expired token.** It fails with
  `notAuthenticated` until the user opens the app.
- **Files opened from the Files app are read-only.** `FileProviderItem.fileCapabilities`
  omits `.allowsWriting`, because no endpoint replaces a file's ciphertext in
  place — `POST /files/upload` creates a *new* record and `PUT /files/{id}/autosave`
  is the Neutrino-native document path, not a general blob replace. Editing a
  Neutrino file in Pages and saving would otherwise appear to work and lose the
  edit. Creating new files works; editing existing ones does not.
- **Thumbnails are not provided.** `fetchThumbnails` would require materializing
  and decrypting content to render a preview, then handing that preview to the
  system — plaintext derived from E2EE content crossing into a system cache. Not
  implemented, deliberately.
- **Conflict handling is minimal.** With no version feed, a file modified
  remotely and locally resolves last-writer-wins at the server. The replicated
  model can express conflicts; without server-side versions to compare, the
  extension has nothing to detect them with.
- **The Spotlight toggle does not cover system indexing of File Provider items.**
  Documented above; the Settings copy says so.
- **Open-in-place classification is heuristic.** SwiftUI's `onOpenURL` discards
  the authoritative `openInPlace` option, so classification is by Inbox
  containment. It fails **safe** — an unrecognised URL is treated as in-place and
  never deleted — but a genuine Inbox copy in an unexpected location would simply
  not be cleaned up. Leaking a temp file is the acceptable direction to be wrong
  in; deleting a user's document is not.
- **Delete is trash, and the Files app calls it Delete.** A user emptying Trash
  in the Files app is not emptying Neutrino's trash. Intentional, and stated in
  the verification doc.

## Acceptance criteria

Status at implementation. Following the convention in
`feature-phase5-sharing-versions-favorites.md`, a box is ticked **only** when a
passing automated test exercises the criterion end to end. Criteria that depend
on the Files app, a live server, a registered domain, or SwiftUI rendering stay
unticked and are marked *partial* or *not verified*, with the specific gap named.

Suite: **424 tests, 9 failures**, against a parent-branch baseline of
**337 / 9**. All 9 are the pre-existing Keychain-dependent failures
(`AuthServiceTests.test_refreshTokenIfNeeded_withFreshToken_isNoOp`,
`DownloadServiceTests.test_download_throwsNotAuthenticated_whenTokenAbsentButKeysPresent`,
3× `KeyImportServiceTests`, 3× `KeyQRDecryptServiceTests`). **87 tests added**
(`FileProviderItemTests` 20, `FileProviderIdentifierTests` 12,
`DriveAPIClientTests` 22, `SpotlightIndexServiceTests` 19,
`IncomingDocumentTests` 14), 0 new failures, none of the 9 fixed.

**No test in this branch is skipped.** An `XCTSkipUnless` was written for the
`spotlightSearch`-off branch and then deleted: a skip proves nothing, and one
sitting behind a ticked box would be exactly the kind of false coverage this
convention exists to prevent. What replaced it is described under Spotlight below.

### File Provider extension

- [x] File and folder identifiers cannot collide, and round-trip back to the right Drive ID and kind.
      `test_fileIdentifier_roundTripsToFileID`, `test_folderIdentifier_roundTripsToFolderID`,
      `test_fileAndFolder_withSameUnderlyingID_produceDistinctIdentifiers`,
      `test_rootContainer_mapsToNilParentID`.
- [x] The Drive root maps to `.rootContainer`, not to a fabricated ID.
      `test_rootContainer_mapsToNilParentID`, `test_identifier_forNilParentID_isRootContainer`.
- [x] A malformed or unprefixed identifier is rejected rather than guessed at.
      `test_parse_returnsNil_forUnprefixedIdentifier`, `test_parse_returnsNil_forEmptyIdentifier`.
- [x] Items built from real API DTOs carry the right filename, parent, size, and content type.
      `test_item_fromFileResponse_mapsFilenameAndSize`, `test_item_fromFolderResponse_hasFolderContentType`,
      `test_item_fromFileResponse_mapsParentIdentifier`, `test_item_atRoot_hasRootContainerParent`.
- [x] A folder is not reported as having a document size, and a file is not reported as a folder.
      `test_item_folder_hasNilDocumentSize`, `test_item_file_isNotFolderContentType`.
- [x] Capabilities allow reading, renaming, moving, and deleting, and a **file** never advertises writable content.
      `test_capabilities_forFile_allowReadingAndDeleting`, `test_capabilities_omitWritingContent`,
      `test_capabilities_forFolder_allowEnumeratingAndAddingSubItems`.
      Scoped to files deliberately: `.allowsAddingSubItems` and `.allowsWriting` are
      **the same bit** (both raw value `2`), as are `.allowsContentEnumerating`
      and `.allowsReading` — the SDK header states this. A folder that accepts new
      files therefore cannot help reporting `.allowsWriting`, so asserting
      otherwise would test an impossibility rather than a decision. The aliasing
      itself is pinned by `test_allowsAddingSubItems_isTheSameBitAsAllowsWriting`
      so the narrower scope reads as intent rather than oversight.
- [x] An unregistered MIME type resolves to something usable rather than to a meaningless dynamic type.
      `test_contentType_fallsBackToFilenameExtension_whenMIMEUnknown`,
      `test_contentType_neverReturnsADynamicType`, `test_contentType_fallsBackToData_whenNothingResolves`.
      `UTType(mimeType:)` returns a synthesised `dyn.a…` type rather than nil for
      Neutrino's own `application/vnd.neutrino.*` MIME types, so a plain non-nil
      check would let a useless dynamic type shadow the filename extension. Found
      by a failing test, not by inspection.
- [x] Files above the materialization ceiling are refused, and files at or below it are permitted.
      `test_canMaterialize_isFalse_aboveCeiling`, `test_canMaterialize_isTrue_atCeiling`,
      `test_canMaterialize_isTrue_forUnknownSize`.
- [x] The drive metadata client sends bearer auth and decodes folder contents, including the folder's own record.
      `test_listFolder_sendsBearerToken`, `test_listFolder_decodesFilesAndFolders`,
      `test_listFolder_decodesOwnFolderRecord`, `test_listRoot_hitsDriveRootPath`.
- [x] A rename and a move are expressed as one `PATCH`, with `folderId` omitted when only the name changes.
      `test_updateFile_rename_omitsFolderIdKey`, `test_updateFile_move_sendsFolderId`,
      `test_updateFile_moveToRoot_sendsNullFolderId`.
- [x] Deleting routes to bulk trash, never to permanent delete.
      `test_trash_postsToBulkTrashEndpoint`, `test_trash_forFolder_sendsFolderIds`.
- [x] A 401 from the metadata client surfaces as not-authenticated rather than a decode failure.
      `test_listFolder_on401_throwsNotAuthenticated`.
- [ ] **Neutrino Drive appears as a location in the Files app and its contents enumerate.**
      *Not verified, and it is the headline claim of this branch.* A File Provider
      extension cannot be instantiated or driven from a unit-test host — see
      "What is actually testable". The extension's **compile and link are**
      verified, as an embedded dependency of the app target. Its behaviour is not.
      Verification doc §1 is the only coverage.
- [ ] A file opens from the Files app, correctly decrypted.
      *Not verified.* `E2EEDownloader` is the same code path the app's download
      uses and is covered by the existing `DownloadServiceTests` regression net,
      but no test drives materialization — that needs `fileproviderd`, a
      registered domain, and a live server.
- [ ] A document saved into Neutrino Drive from Pages or Word arrives encrypted.
      *Not verified.* It goes through `E2EEUploader`, whose sealing is covered by
      `E2EEUploaderTests` and `SealedKeyCryptoTests`, but the `createItem` path
      that reaches it is exercised only by the system.
- [ ] Rename, move, and delete from the Files app reach the right endpoints.
      *Partial.* The request construction is fully tested at the `DriveAPIClient`
      layer (above); the `modifyItem`/`deleteItem` plumbing that calls it is not.
- [ ] Remote changes appear in the Files app.
      *Not verified, and only on re-enumeration.* There is no change feed, so
      `enumerateChanges` reports `syncAnchorExpired` by design. There is no push
      and no background sync. See "The sync anchor problem".
- [ ] Files larger than 64 MB.
      *Not verified, and they do not open.* Refused with an explicit error by
      design; only the threshold logic is tested, not the refusal's presentation
      in the Files app.

### Document Provider

- [ ] Pages, Numbers, Word, Excel, and third-party pickers can open Neutrino files.
      *Not verified.* Delivered by the File Provider domain rather than by a
      separate target — see "Document Provider: why there is no second target".
      No legacy target was built, deliberately. Requires the real apps on a real
      device; verification doc §2.

### Open In Place

- [x] A document handed over in place is never deleted after import.
      `test_classify_urlOutsideInbox_isInPlace`, `test_inPlaceDocument_isNotDeletable`.
- [x] A copy iOS placed in the app's Inbox is still cleaned up.
      `test_classify_urlInsideInbox_isInboxCopy`, `test_inboxCopy_isDeletable`.
- [x] An unrecognised URL fails safe — treated as in-place, therefore not deleted.
      `test_classify_unknownURL_defaultsToInPlace`.
- [x] A file:// URL that merely contains the word "Inbox" in a filename is not misclassified.
      `test_classify_filenameContainingInbox_isNotInboxCopy`.
- [x] Reading an in-place document balances its security scope even when the read throws.
      `test_read_releasesSecurityScope_onThrow`.
- [ ] Importing a key from a file in iCloud Drive leaves that file in place.
      *Partial.* Classification and the no-delete rule are tested; the actual
      security-scoped read of a real provider URL needs a device and another
      storage provider. Verification doc §3.
- [ ] `LSSupportsOpeningDocumentsInPlace = true` does not regress the existing key-import flow.
      *Partial.* The import itself is unchanged and still covered by
      `KeyImportServiceTests`; the URL-delivery half depends on the OS.

### Spotlight Search

- [x] Nothing is indexed unless the user turns the setting on — the default is off.
      `test_isEnabled_defaultsToFalse`, `test_index_doesNothing_whenDisabled`.
- [x] Indexed attributes carry metadata only, and no content-bearing field is ever populated.
      `test_attributeSet_containsNoTextContent`, `test_attributeSet_containsNoContentDescription`,
      `test_attributeSet_containsNoThumbnailData`, `test_attributeSet_carriesDisplayNameAndType`.
- [x] Every item is written under one domain identifier, so a single call removes all of them.
      `test_searchableItem_carriesDomainIdentifier`, `test_deindexAll_usesDomainIdentifier`.
- [x] Turning the setting off de-indexes what was already written.
      `test_setEnabled_false_triggersDeindex`.
- [x] A Spotlight activity resolves back to the Drive item it came from, and rejects foreign activities.
      `test_driveItemID_fromSpotlightActivity_returnsIdentifier`,
      `test_driveItemID_fromUnrelatedActivity_returnsNil`.
- [x] Indexing is gated on the build flag *and* the user setting composed together, not on the setting alone.
      `test_isIndexingAllowed_requiresBothGates`, `test_index_writesOnlyWhenIndexingIsAllowed`.
      *This is deliberately narrower than "the flag off means no writes".*
      `FeatureFlags.spotlightSearch` is a `static let`, so no test can flip it and
      no test can observe the flag-off branch executing. What is proven is that
      `isIndexingAllowed` tracks the flag and that `index(items:)` consults
      nothing else. The flag-off branch itself is unexecuted by any test.
- [ ] Searching a filename from the iOS home screen finds it and opens the app to that item.
      *Not verified.* `CSSearchableIndex` writes to a system daemon and the home
      screen search UI is not addressable from XCTest. The activity-to-item
      resolution *is* tested; the round trip through Spotlight is not.
      Verification doc §4.
- [ ] De-indexing on logout actually removes results from system search.
      *Partial.* The call is tested; that Spotlight honours it is not observable
      in-process.
- [ ] The Settings copy accurately conveys that File Provider items are indexed by the system regardless.
      *Not verified* — SwiftUI, no view tests. Correct by inspection only, and it
      is the claim most worth reading carefully, because a privacy control that
      overstates its reach is worse than no control.

### Cross-cutting

- [x] Download still works after the `E2EEDownloader` extraction.
      The pre-existing `DownloadServiceTests` pass unchanged as the regression net,
      including the version-path tests added in Phase 5.
- [x] `DownloadService` keeps its public surface and its published state.
      `test_initialState_isNotDownloading`, `test_initialState_progressIsZero`,
      `test_initialState_errorIsNil` pass unchanged.
- [ ] The File Provider extension and the share extension both still build.
      **Verified for compile and link** — `xcodebuild` builds both as embedded
      dependencies of the app target. Not ticked because "builds" is not
      "behaves", and this box reads as the latter.
- [ ] Each feature flag set to `false` removes its surface entirely.
      *Partial.* `spotlightSearch` is asserted
      (`test_index_doesNothing_whenFeatureFlagDisabled`). `filesAppIntegration`
      gates domain registration, which no test can observe; `openInPlace` gates a
      plist value that is fixed at build time.
</content>
</invoke>
