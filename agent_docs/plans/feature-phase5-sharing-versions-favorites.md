# Implementation Plan: Phase 5 — Sharing, Version History, Favorites

## What is changing and why

Three of the five Phase 5 items in `agent_docs/mvp.md` land here: **Sharing**,
**Version History**, and **Favorites**. Smart Offline Sync and Large File
Streaming stay out of scope.

All three compose endpoints that already exist in the Rust backend at
`/Users/williamcherry/Playground/neutrino` — **no backend changes**. Every
request/response shape below was read out of the actual handler source, not
inferred from the endpoint list, because two of them differ from the brief:

| Briefed as | Actually |
|---|---|
| `POST .../share-link` | **`PUT`** `/files/{id}/share-link` (`#[put]` in `src/drive/sharing/api.rs:80`). `GET` also *creates* a default link if none exists. |
| "find the star mutation" | No dedicated endpoint. It is `PATCH /api/v1/drive/files/{id}` with `{"isStarred": true}` — `UpdateFileRequest.is_starred` in `src/drive/filesystem/dto.rs:59`. |

This branch **stacks on `feature/phase2-biometrics-share-background`** (PR #7),
not on `main`.

## Layers affected

- **Backend — none.** Read-only audit of the Rust source only.
- **Service — `SealedKeyCrypto`** *(new — `Services/SealedKeyCrypto.swift`)*.
  The DEK seal/unseal primitives, **extracted** from the inline bodies of
  `E2EEUploader.upload` and `DownloadService.download` so upload, download, and
  sharing provably share one definition. See "Why extract the crypto".
- **Service — `SharingService`** *(new — `Services/SharingService.swift`)*.
  Permissions CRUD, share links, user lookup/search, and the DEK re-wrap.
- **Service — `VersionHistoryService`** *(new — `Services/VersionHistoryService.swift`)*.
  Version listing and restore.
- **Service — `DownloadService`** *(modified)*. A `versionID` parameter on
  `download(...)`, so a historical version goes through the **same** decrypt
  path as a current file rather than a parallel one.
- **Service — `DriveService`** *(modified)*. `setStarred`, `loadStarred`, a
  `starredItems` published array, and `isStarred` decoding on the existing file
  and folder response structs.
- **Model — `DriveItem`** *(modified)*. Gains `isStarred`, declared last with a
  `false` default so every existing call site and test still compiles.
- **Model — `DriveSection`** *(modified)*. Gains `.starred`, which slots into
  the iPhone segmented picker and the iPad sidebar with no layout work.
- **View — `ShareSheet`** *(new)*, **`VersionHistorySheet`** *(new)*,
  **`FileBrowserView`** *(modified — context-menu entries)*.
- **Config — `FeatureFlags`** *(modified)*. `sharing`, `versionHistory`,
  `favorites`.
- **Config — `project.yml`** *(modified)*. `SealedKeyCrypto.swift` must be added
  to the **share-extension** source list too, because `E2EEUploader` now calls
  it and that target compiles `E2EEUploader.swift`. Forgetting this breaks the
  extension build, not the app build — a failure mode worth naming.
- **Tests** — `SealedKeyCryptoTests`, `SharingServiceTests`,
  `VersionHistoryServiceTests`, additions to `DriveServiceTests` and
  `DownloadServiceTests`.

## The E2EE sharing protocol — the part that must not be guessed

The backend contract is unambiguous, so this is **not** a guess. Evidence:

- `src/drive/encryption/model.rs:4-6` — "`encrypted_file_key` is the DEK sealed
  with the user's Curve25519 public key (libsodium `crypto_box_seal`),
  base64url-encoded."
- `src/drive/encryption/api.rs:32-37` — `ShareFileKeyRequest { recipientId,
  encryptedFileKey }`, camelCase, "DEK sealed to the recipient's Curve25519
  public key (base64url)".
- `src/auth/dto.rs` — `SetPublicKeyRequest`/`PublicKeyResponse`: "Base64url-encoded
  Curve25519 public key (32 bytes)", response `{ userId, publicKey }`.
- The web app already implements exactly this in
  `web/apps/web/src/app/(apps)/drive/ShareDialog.tsx:109-129`, and its
  `encryptFileKey` is `sodium.crypto_box_seal` + base64url
  (`web/packages/e2e-crypto/src/crypto.ts:129`).

This is byte-for-byte the scheme `E2EEUploader` already uses to seal a DEK to
the *owner's* own key (`sodium.box.seal` + `bin2base64(.URLSAFE_NO_PADDING)`).
Sharing changes only the recipient public key. **No new crypto is introduced.**

Client sequence for "add person to a file":

```
1. GET  /api/v1/auth/users/lookup?email=…        → { id, email, name }
2. POST /api/v1/drive/files/{id}/permissions     ← { userId, userEmail, userName, role }
3. GET  /api/v1/drive/files/{id}/key             → { encryptedFileKey }   (ours)
4. box_seal_open(encryptedFileKey, our keypair)  → dek
5. GET  /api/v1/auth/users/{recipientId}/public-key → { publicKey }
6. box_seal(dek, recipientPublicKey)             → encryptedFileKey'
7. POST /api/v1/drive/files/{id}/key/share       ← { recipientId, encryptedFileKey' }
```

**Step 2 must precede step 7.** `EncryptionService::share_file_key`
(`src/drive/encryption/service.rs:79-88`) rejects the key share with
`400 RECIPIENT_NO_ACCESS` unless the recipient already holds a permission on the
file. Getting this order wrong yields a granted permission plus a missing key —
i.e. a recipient who can see the file listed and cannot open it. The ordering is
asserted by a test.

**Steps 3–7 are skipped for folders.** There is no folder-level DEK; folder
sharing grants the permission only. Files inside a shared folder each need their
own key share, which this MVP does **not** walk — see "Known gaps".

**Failure of the key share is surfaced, not swallowed.** The web app deliberately
fails silently here (`ShareDialog.tsx`: "Silent failure — if either party has no
keypair the file is plaintext"). Copying that would be wrong on mobile, where
the user has no console: a recipient who cannot decrypt is the exact bug this
feature exists to avoid. Instead the sheet reports
"Shared, but *name* cannot decrypt it yet — they have not set up an encryption
key", with the permission left in place.

## Why extract the crypto

`E2EEUploader.upload` seals the DEK inline; `DownloadService.download` unseals it
inline. Sharing needs both halves. Writing a third copy inside `SharingService`
is precisely the "wrong key-wrap silently produces files the recipient cannot
decrypt" risk the brief names — a divergence would not fail any build.

So the two inline bodies move into `SealedKeyCrypto` and both existing call sites
delegate to it. This mirrors the reasoning already recorded in `project.yml` for
the share extension ("compiling literally the same file guarantees that more
strongly than a framework's API contract would"). The refactor is behaviour-preserving
and is covered by the existing `E2EEUploaderTests` / `DownloadServiceTests`
as a regression net.

## Version history and the DEK question

Historical versions are **encrypted too**, and the server stores **no
per-version key**: `FileVersionResponse` (`src/drive/storage/dto.rs:104-112`)
has no key field, and `create_version_snapshot_record`
(`src/drive/storage/service.rs:589+`) is a plain `std::fs::copy` of the blob.
`file_key_refs` holds exactly one row per `(file_id, user_id)`, upserted.

So a historical version decrypts **only if it was encrypted with the DEK
currently stored for that file**. That holds today: the web app resolves the DEK
once per file and reuses it on save, generating a new one only when no key ref
exists (`web/apps/web/src/hooks/useEncryptedDocumentContent.ts:121-131`). The
iOS app never creates versions at all — it only does full uploads, which create
new files.

Therefore version download = fetch the file's current DEK, fetch
`/versions/{vid}/download`, decrypt with the identical
`[24-byte header][ciphertext]` secretstream path. This is why `DownloadService`
gains a `versionID` parameter instead of a new method: the decrypt code is
literally shared.

**Recorded as a standing risk, not a defect introduced here:** if any client ever
rotates a file's DEK, every older version becomes permanently undecryptable and
nothing in the schema would detect it. That is a backend/web design property; it
is out of scope to fix from the iOS client, but it belongs in the risk list
because version history is the feature that would expose it.

## Favorites

- Read: `GET /api/v1/drive/starred?limit=…` → `{ files: [...], folders: [...] }`
  (`StarredContentsResponse`). Default limit server-side is **5**, which is a
  "Quick Access" default, not a favorites list — the client passes an explicit
  larger limit.
- Write: `PATCH /api/v1/drive/files/{id}` or `/folders/{id}` with
  `{"isStarred": bool}`. Both responses carry `isStarred` back.
- `isStarred` is added to the existing `APIFileResponse` / `APIFolderResponse`
  decoding as `Bool?` decoded to a `false` default, so a server that omits it
  cannot break folder listing.

Optimistic toggle with rollback on failure, matching `rename`/`move`.

## Feature flags

```swift
static let sharing: Bool = true          // Share sheet + E2EE key re-wrap
static let versionHistory: Bool = true   // Version list, restore, historical view
static let favorites: Bool = true        // Star toggle + Favorites section
```

When `sharing` is false the context-menu entry is hidden and no permission,
lookup, or key-share request is ever issued. When `favorites` is false the
`.starred` section is dropped from `DriveSection.allCases` so neither the picker
nor the sidebar shows it.

## Testing

Unit tests via `MockURLProtocol`, matching the existing convention:

- `SealedKeyCryptoTests`
  - **Full offline share round trip**: encrypt a payload with a DEK → seal to
    sender → unseal as sender → re-seal to recipient → unseal as recipient →
    decrypt the payload. Asserts the recovered plaintext equals the original.
    This is the closest an in-process test can get to "the recipient can
    actually decrypt", and it is the single most valuable test here.
  - Sealing to a *wrong* recipient key does not open with the recipient's
    private key (guards against a silently-wrong wrap).
  - base64url round-trips without padding.
- `SharingServiceTests`
  - `addPerson` issues lookup → grant → key-share **in that order** (asserted on
    a recorded request sequence, because the backend rejects the reverse).
  - The `encryptedFileKey` sent to `key/share` opens with the *recipient's*
    private key and **not** the sender's.
  - Folder sharing grants the permission and issues **no** key-share call.
  - A recipient with no registered public key (404) surfaces the
    "cannot decrypt yet" state and leaves the permission granted.
  - `listPermissions` / `revoke` / share-link create+fetch decode correctly.
- `VersionHistoryServiceTests` — version list decodes and sorts newest-first;
  restore posts to the right path.
- `DownloadServiceTests` — the version path hits
  `/files/{id}/versions/{vid}/download` while still fetching the key from
  `/files/{id}/key`.
- `DriveServiceTests` — star toggles optimistically and rolls back on server
  error; `loadStarred` populates `starredItems`.

## Known gaps / risks

- **The end-to-end property — "a second real user can decrypt the shared file" —
  is NOT proven by any test here.** It needs a live server and a second account
  with a registered public key. `SealedKeyCryptoTests` proves the crypto
  composition in-process; it cannot prove the server stores and returns the
  shared key ref correctly. This is the headline caveat and is the first item in
  the verification doc.
- **Folder sharing does not cascade file keys.** Granting a folder permission
  makes the folder visible, but each file inside still needs its own key share.
  Recipients will see folder contents they cannot decrypt. Mitigated by copy in
  the sheet stating this; the real fix (walk the subtree, share every DEK) is
  deliberately deferred — it is an unbounded, partially-failing batch operation
  that deserves its own design.
- **DEK rotation would orphan old versions** — see above.
- **Revocation does not re-key the file.** Revoking a permission removes the
  recipient's key ref, but they may have already downloaded the DEK. True
  forward secrecy needs re-encryption under a fresh DEK. Standard for this class
  of product; stated plainly rather than implied.
- **Share links and E2EE are in tension.** A share link grants access to
  ciphertext, but a link recipient has no keypair and therefore cannot decrypt.
  The link UI is implemented because the endpoint exists, but the sheet says so
  explicitly rather than implying links work for encrypted files.
- **`GET /share-link` has a side effect** — it creates a default
  `anyoneWithLink`/`viewer` link when none exists
  (`src/drive/sharing/api.rs:48-63`). So the sheet must not fetch a link merely
  to display state, or opening the sheet would silently create one. The sheet
  therefore only fetches on explicit user action.
- **`visibility` is asymmetric.** The request enum serialises camelCase
  (`anyoneWithLink`), the response returns the raw DB string
  (`anyone_with_link`). The client tolerates both.

## Acceptance criteria

Status at implementation. Following the convention in `feature-photo-auto-sync.md`,
a box is ticked **only** when a passing automated test exercises the criterion end
to end. Criteria that are unit-tested but depend on a live server, a second real
account, or SwiftUI rendering stay unticked and are marked *partial* or
*not verified*, with the specific gap named. The remaining coverage is
`feature-phase5-sharing-versions-favorites-verification.md`, **which has not been
run** — no live server was available.

Suite: **337 tests, 9 failures**, against a parent-branch baseline of **285 / 9**.
All 9 are the pre-existing Keychain-dependent failures
(`AuthServiceTests.test_refreshTokenIfNeeded_withFreshToken_isNoOp`,
`DownloadServiceTests.test_download_throwsNotAuthenticated_whenTokenAbsentButKeysPresent`,
3× `KeyImportServiceTests`, 3× `KeyQRDecryptServiceTests`). 52 tests added, 0 new
failures, none of the 9 fixed.

### Sharing

- [x] A DEK sealed to a recipient's public key can be opened by that recipient and decrypts the file; it cannot be opened with the sender's keys.
      `test_shareRoundTrip_recipientCanDecryptTheFile`,
      `test_keySealedToRecipient_doesNotOpenWithSenderKeys`,
      `test_dekSealedToWrongKey_doesNotOpenForIntendedRecipient`.
      **This is the client-side crypto only** — see the unticked end-to-end criterion below.
- [x] The key posted to `key/share` is the file's real DEK re-wrapped to the recipient, not the sender's copy forwarded.
      `test_addPerson_postsDEKResealedToRecipientPublicKey` decodes the actual
      request body and opens it with the recipient's private key.
- [x] The permission is granted *before* the key share, as the backend requires.
      `test_addPerson_issuesLookupThenGrantThenKeyShare_inThatOrder`.
- [x] The wrap is a bare `crypto_box_seal` + unpadded base64url, so it interoperates with the web client.
      `test_sealedOutput_isPlainCryptoBoxSeal`, `test_encodeBase64URL_producesUnpaddedOutput`,
      `test_encodeBase64URL_usesURLSafeAlphabet`.
- [x] A malformed or wrong-length recipient public key is refused rather than sealed to.
      `test_seal_returnsNil_forMalformedPublicKey`, `test_seal_returnsNil_forWrongLengthPublicKey`.
- [x] A recipient with no registered public key yields a partial-success state, and the granted permission survives.
      `test_addPerson_whenRecipientHasNoPublicKey_throwsKeyShareFailedButKeepsPermission`.
- [x] An unknown email fails before any permission is granted.
      `test_addPerson_whenUserNotFound_throwsUserNotFoundAndGrantsNothing`.
- [x] Folder sharing grants a permission and touches no key endpoint.
      `test_addPerson_forFolder_grantsPermissionAndIssuesNoKeyShare`.
- [x] Permissions list, role update, and revoke behave correctly.
      `test_loadPermissions_decodesPermissionList`, `test_updateRole_replacesRoleInPublishedList`,
      `test_revoke_removesPermissionFromPublishedList`.
- [x] Share-link creation uses `PUT` and sends camelCase `anyoneWithLink`.
      `test_createShareLink_usesPUTAndDecodesToken`.
- [x] Opening the sheet does not implicitly call `GET /share-link`, which would create a link as a side effect.
      `test_loadPermissions_doesNotTouchShareLinkEndpoint`.
- [ ] **A second real user, on a real server, can open a file shared from this app.**
      *Not verified — and this is the single most important claim in the whole
      branch.* It requires a live backend and a second account with a registered
      public key; nothing automated covers it. What *is* proven is every
      client-side link in the chain (the crypto round trip, the exact bytes
      posted to `key/share`, and the call ordering the server demands). What is
      **not** proven is that the server stores and returns that key ref intact,
      that the recipient's client reads it from the same place, or that the
      recipient's stored public key is the one their private key matches.
      Verification doc §1 is the only coverage.
- [ ] The share sheet renders permissions, roles, and the partial-success warning.
      *Not verified* — SwiftUI views have no test target here; correct by inspection only.
- [ ] Revoking access stops an existing recipient from decrypting.
      *Not verified, and it does not.* Revocation removes the key ref, but a
      recipient who already fetched the DEK retains it. Named in "Known gaps".

### Version History

- [x] A historical version's blob is fetched from the version endpoint, and the current file's from the file endpoint.
      `test_blobPath_withVersionID_pointsAtVersionDownloadEndpoint`,
      `test_blobPath_withoutVersionID_pointsAtCurrentFile`,
      `test_blobPath_versionAndCurrentPathsDiffer`.
- [x] A version download gets a transfer ID distinct from the current file's.
      `test_blobTransferID_isDistinctPerVersion`.
- [x] The version list decodes and is ordered newest-first regardless of server order.
      `test_loadVersions_decodesVersionList`, `test_loadVersions_sortsNewestFirst_regardlessOfServerOrder`.
- [x] Both the zoned RFC 3339 dates the version DTO emits and bare `NaiveDateTime` decode.
      `test_loadVersions_decodesZonedISO8601Date`, `test_loadVersions_decodesNaiveDateTimeFallback`.
- [x] Restore posts to the restore path and refreshes the list.
      `test_restore_postsToRestorePathAndReloadsVersions`.
- [ ] A historical version actually decrypts and opens in the viewer.
      *Partial.* The decrypt path is literally the same code as a current-file
      download (a `versionID` parameter, not a second method), and that path is
      exercised by the existing download tests. But **no test drives a real
      version download end to end**: the flow requires an encryption keypair in
      the Keychain, which this test host does not persist — the same limitation
      behind the pre-existing `test_download_throwsNotAuthenticated_…` failure.
      Only path construction is asserted.
- [ ] Restoring a version leaves the file openable, and the pre-restore content recoverable.
      *Not verified* — needs a live server.
- [ ] Old versions remain decryptable over time.
      *Not verified, and structurally at risk.* Nothing stores a per-version key,
      so this holds only while clients reuse a file's DEK. A DEK rotation by any
      client would silently orphan every older version. See "Known gaps".

### Favorites

- [x] Starring updates the item and the Starred section immediately, without a refetch.
      `test_setStarred_marksItemStarredImmediately`,
      `test_setStarred_addsItemToStarredSectionImmediately`.
- [x] Unstarring removes the item from the Starred section.
      `test_setStarred_false_removesItemFromStarredSection`.
- [x] Starring twice does not duplicate the row; an unknown item is a no-op.
      `test_setStarred_doesNotDuplicateWhenCalledTwice`, `test_setStarred_forUnknownItem_isNoOp`.
- [x] The star is a `PATCH` to the item with `{"isStarred": …}`, on the file or folder endpoint as appropriate.
      `test_setStarred_patchesFileWithIsStarredField`, `test_setStarred_forFolder_patchesFolderEndpoint`.
- [x] A failed star rolls back rather than leaving a star the server never recorded.
      `test_setStarred_onServerError_rollsBackOptimisticChange`.
- [x] The Starred section loads and sends an explicit limit rather than accepting the 5-item default.
      `test_loadSection_starred_populatesStarredItems`, `test_loadSection_starred_sendsExplicitLimit`.
- [x] A server response omitting `isStarred` does not break listing.
      `test_loadSection_myDrive_toleratesMissingIsStarredField`.
- [x] `.starred` is gated by the feature flag for presentation but always present for switch exhaustiveness.
      `test_visibleCases_includesStarred_whenFeatureEnabled`,
      `test_allCases_alwaysContainsStarred_soSwitchesStayExhaustive`.
- [ ] The star action appears in the context menu and the Starred tab renders.
      *Not verified* — SwiftUI, no view tests.

### Cross-cutting

- [x] Upload and download still work after the crypto extraction.
      The pre-existing `E2EEUploaderTests`, `UploadServiceTests`, and
      `DownloadServiceTests` pass unchanged as the regression net.
- [ ] The share extension still builds and uploads after `SealedKeyCrypto` joined its source list.
      *Not verified* — the test bundle cannot link an app-extension target, so
      only the app target's compile is proven. A missing entry in `project.yml`
      would break the extension build specifically.
- [ ] Each feature flag set to `false` removes its surface entirely.
      *Partial* — `DriveSection.visibleCases` is asserted for `favorites`. The
      `sharing` and `versionHistory` flags gate SwiftUI branches that no test
      covers.
