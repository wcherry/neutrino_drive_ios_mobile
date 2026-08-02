# Implementation Plan: Phase 5 Streaming + Smart Offline Sync, Phase 6 iPad

## What is changing and why

The last four roadmap items in `agent_docs/mvp.md`:

1. **Large File Streaming** (Phase 5) — stream video/audio without a full download.
2. **Smart Offline Sync** (Phase 5) — automatically cache recent and frequently-accessed files.
3. **Phase 6 iPad features** — multi-window, drag and drop, Stage Manager.
4. **Final roadmap update** — make `mvp.md` reflect the whole stack honestly.

This branch **stacks on `feature/phase3-ios-ecosystem-integration`** (PR #9), which stacks
on #8, which stacks on #7. Branched from `a05e083`, not from `main`.

**No backend changes.** The Rust source at `/Users/williamcherry/Playground/neutrino` was read
strictly read-only, and three of its properties changed the design materially — see the two
"findings" sections below.

---

## Finding 1 — the ciphertext format, and what it actually permits

The brief asked me to determine honestly whether the existing format permits ranged decryption,
and to say so plainly if it does not. The answer is more interesting than either of the two
options the brief anticipated, so it is worth stating precisely.

### What the format is

Both clients produce **one** secretstream message covering the entire file:

- iOS — `E2EEUploader.swift:140`: `filePushStream.push(message: Array(plainData), tag: .FINAL)`
- Web — `web/packages/e2e-crypto/src/crypto.ts:88`:
  `crypto_secretstream_xchacha20poly1305_push(state, plaintext, null, TAG_FINAL)`

Wire layout:

```
[24-byte header][1-byte encrypted tag][N-byte encrypted body][16-byte Poly1305 MAC]
```

so `ciphertextLength == plaintextLength + 41`.

### The naive conclusion, which is wrong

`crypto_secretstream_xchacha20poly1305_pull` is one-shot per message. There is no
init/update/final for a *single* message. So at the libsodium public-API level, decryption
requires the whole ciphertext resident **and** produces the whole plaintext resident — the
~400 MB-for-a-200 MB-video shape that PR #6 documented and PR #9 capped at 64 MB.

It would be easy to stop here and report "monolithic blob, random access impossible, needs a
format change". **That conclusion would be wrong**, and shipping the 64 MB cap on the strength
of it would leave a fixable bug unfixed.

### What the construction actually is

libsodium's secretstream is not a black box; it is a documented composition
(`crypto_secretstream_xchacha20poly1305_push` in `secretstream_xchacha20poly1305.c`):

- `k' = crypto_core_hchacha20(header[0..16], key)`, and the ChaCha20-IETF nonce is
  `[4-byte LE counter = 1][header[16..24]]`.
- Counter block 0 produces the Poly1305 one-time key.
- Counter block 1 encrypts the 1-byte tag (padded to a full 64-byte block).
- **The message body is `crypto_stream_chacha20_ietf_xor_ic(m, nonce, ic = 2, k')`.**
- Poly1305 runs over `[tag block (64 B)][body][pad][adlen LE64][64 + mlen LE64]`.

The body is therefore a **pure counter-mode stream cipher**. Plaintext byte `i` is
`ciphertextBody[i] XOR keystream(ic = 2 + i/64)[i % 64]`. Random access is *arithmetic*, not a
format capability — any byte range can be decrypted independently, given the header and the DEK.

So, stated exactly:

| Property | Status |
|---|---|
| Constant-memory **sequential** decrypt | **Possible, and fully authenticated.** Poly1305 has a streaming init/update/final API. |
| **Random access** to an arbitrary byte range | **Possible** — ChaCha20 is seekable via `_ic`. |
| **Authenticating** a range without reading the whole message | **Impossible.** One MAC covers the whole message. |

The last row is the real constraint, and it is a property of AEAD-over-one-message in general,
not of a mistake anyone made here. A chunked secretstream (many messages, each individually
authenticated) is what would fix it — that **is** a format change requiring backend and web
agreement, and it stays out of scope. It is recorded in "Recommended follow-up" below.

### What this branch therefore builds

`SecretStreamCrypto` (new, `Services/SecretStreamCrypto.swift`) reimplements the *pull* half of
the construction over the raw C API (`import Clibsodium`, an SPM product swift-sodium already
vends), in two modes:

- **`decrypt(fileAt:to:key:)`** — chunked, constant memory (~1 MB regardless of file size),
  **fully authenticated**: every ciphertext byte is fed to a streaming Poly1305 and the MAC is
  verified before the output is handed back. This is a drop-in replacement for the existing
  whole-file decrypt with identical output bytes.
- **`RandomAccessReader`** — seek to any plaintext offset and decrypt just that span.
  **Unauthenticated by construction.** The type is named and documented so no call site can
  adopt it without noticing.

**This is not new cryptography and not a new format.** It is the same construction, decrypted
incrementally, producing byte-identical plaintext. The test that makes that claim safe is a
round-trip against libsodium's own implementation — encrypt with `Sodium().secretStream` exactly
as `E2EEUploader` does, decrypt with this code, assert equality — plus a tamper test asserting
the MAC actually rejects a flipped bit. If those two tests do not pass, none of this ships.

### The security boundary, stated once

Because ranged reads cannot be authenticated, this branch enforces a rule:

> **Plaintext that is written to disk, materialized for another app, exported, or made
> available offline is ALWAYS produced by the authenticated path. The unauthenticated
> random-access path is used only for transient media playback, behind its own flag.**

That means: `E2EEDownloader`, the File Provider, offline caching, drag-out export — all
authenticated. Only `EncryptedMediaStream` uses random access, and only to feed
AVFoundation during playback.

The residual risk is real and I am not going to soften it: while seeking through a video, the
app feeds AVFoundation bytes whose integrity has not been verified, from a server the E2EE
threat model says not to trust. `FeatureFlags.largeFileStreaming = false` falls back to the
authenticated full-download path, and is the correct setting for a deployment that will not
accept that trade. A size threshold means the trade is only ever taken for genuinely large
media; see the next section for a verification idea that was designed and then rejected.

### Sequential-prefix verification — designed, then deliberately not built

The plan above originally called for a running Poly1305 over whatever contiguous prefix the
player happened to read, so that straight-through playback would at least be authenticated *by
completion*. **I implemented the design far enough to see it was a bad idea, and dropped it.**

AVFoundation does not read an MP4 front to back. It requests the content length, then the
`moov` atom — which in a non-faststart file sits at the **end** — and only then seeks back to
the media data. A "contiguous prefix from byte 0" therefore essentially never completes for
real media. The check would have reported `unverified` in virtually every real session while
the presence of an `integrityState` API implied that verification was meaningfully happening.
A verification feature that silently never fires is worse than none: it invites the next
reader to believe a guarantee that is not there.

What bounds the risk instead is **scope**, which is enforced and testable:

- A size threshold (`streamingThresholdBytes`, 32 MB). Below it, media is downloaded in full
  and authenticated, so the trade is only taken where it buys something real.
- The unauthenticated reader is reachable *only* from `StreamingPlaybackService`. Download,
  offline caching, File Provider materialization, and drag-out export all call
  `SecretStreamCrypto.decrypt(fileAt:to:key:)`, which verifies the MAC and fails closed.
- `FeatureFlags.largeFileStreaming = false` restores full-download playback with full
  authentication.
- The player UI states plainly that a streamed file's integrity check cannot be completed.

The honest summary: **streamed playback is not integrity-protected, and this branch does not
pretend otherwise.** Closing that properly requires a chunked secretstream, below.

---

## Finding 2 — the backend cannot supply an access-frequency signal

The brief asked me to decide between tracking access locally and using
`/api/v1/drive/quick-access` or `/api/v1/drive/files/{id}/activity`, verifying the shapes in the
Rust source. I verified them, and **both server-side options are unusable**. Three separate
reasons, each sufficient on its own:

1. **The activity log is never written for file access.** `ActivityService.log` →
   `ActivityRepository.insert_entry` has exactly three callers in the whole backend —
   `src/drive/comments/service.rs:81` and `src/drive/suggestions/service.rs:{71,149,216}`.
   Nothing in `src/drive/storage/api.rs` logs a view, an open, or a download. So
   `GET /files/{id}/activity` returns comment and suggestion events only, and reports *nothing*
   about how often a file is actually opened.

2. **`quick-access`'s scoring query is broken and fails silently.**
   `src/drive/priority/service.rs:38-52` groups on `al.action_type`, but the column in
   `file_activity_log` is `action` (`src/schema.rs`, and `ActivityEntry.action` in
   `src/drive/activity/model.rs`). The `sql_query` therefore errors, and
   `.load(conn).unwrap_or_default()` swallows the error into an empty vec, which takes the
   `if scored.is_empty()` branch. **`/quick-access` returns "the N most recently updated files"
   in every case.** The frequency scoring it appears to implement has never run.

3. **The limit is hardcoded.** `src/drive/priority/api.rs:38` passes a literal `8`; it is not a
   query parameter. Eight recently-modified files is not a corpus you can build a cache policy on.

Reporting these is in scope; fixing them is not — the backend is read-only for this pass.

**Therefore access tracking is local**, in a new `FileAccessTracker`. That is also the answer I
would have argued for on privacy grounds even had the endpoints worked: "which files this user
opens, and how often" is exactly the behavioural metadata an E2EE product exists to withhold,
and shipping it to the server to power a *client-side* cache would be a poor trade. The local
signal is strictly better here — it sees File Provider materializations and offline opens that
never produce a server request at all.

---

## Layers affected

- **Backend — none.** Read-only audit only.
- **Service — `SecretStreamCrypto`** *(new)*. Constant-memory authenticated decrypt +
  unauthenticated random access. Compiled into app, File Provider, and share extension.
- **Service — `E2EEDownloader`** *(modified)*. Routes through the streaming decrypt; the
  in-memory path is deleted, not kept alongside. `maxDecryptBytes` semantics preserved.
- **Service — `EncryptedMediaStream`** *(new)*. Ranged ciphertext fetch + ranged decrypt.
- **Service — `EncryptedMediaResourceLoader`** *(new, in `StreamingPlaybackService.swift`)*.
  The thin `AVAssetResourceLoaderDelegate` over it.
- **Service — `StreamingPlaybackService`** *(new)*. Decides stream-vs-download for an item and
  builds the `AVPlayer`.
- **Service — `FileAccessTracker`** *(new)*. Local recency/frequency signal.
- **Service — `SmartOfflineSyncService`** *(new)*. Budgeted, evicting, constraint-gated cache.
- **Service — `OfflineService`** *(modified)*. Gains an eviction-capable API and a
  managed-vs-pinned distinction. Existing behaviour unchanged.
- **View — `MediaPlayerView`** *(new)*, **`SmartOfflineSettingsView`** *(new)*,
  **`FileBrowserView`** / **`FilesView`** *(modified — drag/drop, multi-window)*.
- **App — `NeutrinoDriveApp`** *(modified)*. A second `WindowGroup` for document windows.
- **Config — `FeatureFlags`** *(modified)*. Four new flags.
- **Config — `project.yml`** *(modified)*. `Clibsodium` product dependency on all three
  code-sharing targets; new shared source files.
- **Tests** — `SecretStreamCryptoTests`, `EncryptedMediaStreamLoaderTests`,
  `FileAccessTrackerTests`, `SmartOfflineSyncServiceTests`, `DragAndDropTests`,
  `DocumentWindowTests`, additions to `OfflineServiceTests`.

## Feature flags

| Flag | Default | When false |
|---|---|---|
| `largeFileStreaming` | `true` | Media opens via the existing full-download + QuickLook path. No resource loader is installed, so no unauthenticated byte is ever produced. |
| `smartOfflineSync` | `true` | No access is recorded, no automatic caching runs, the Settings section is hidden. Manual "Make Available Offline" is untouched. |
| `multiWindow` | `true` | The document `WindowGroup` is not declared and no `openWindow` call site is reachable. |
| `dragAndDrop` | `true` | No `.draggable`/`.dropDestination` modifiers are attached. |

## Known risks and edge cases

- **The streaming decrypt is the highest-risk change in this branch.** It sits under *every*
  download in the app. A silent divergence would produce plausible garbage rather than an
  error. Mitigation: differential tests against libsodium across sizes that straddle the
  64-byte block boundary and the 1 MB chunk boundary (0, 1, 63, 64, 65, 1 MB ± 1, 4 MB), each
  asserting byte equality; plus tamper-rejection tests at the tag, body, and MAC.
- **Range requests must actually be honoured.** The backend serves blobs via
  `actix_files::NamedFile::into_response`, which implements `Range`/206 natively
  (`src/drive/storage/api.rs:415`). A deployment behind a proxy that strips `Range` would
  silently return 200-with-everything; the loader detects a 200 where it asked for 206 and
  fails rather than mis-indexing the bytes.
- **Storage budget accounting must not drift from disk.** The budget is recomputed from actual
  file sizes, not from a running total, so a failed write cannot inflate the accounting.
- **Eviction must never delete a user-pinned file.** Manual offline files and smart-cached
  files live in the same manifest; eviction filters on `isManaged` and the tests assert a
  pinned file survives a budget overflow that evicts everything else.
- **Multi-window state.** Two windows share the same services. `@StateObject` at app scope is
  per-scene in SwiftUI; services that must be shared are passed via environment from a single
  owner.
- **Drag-out exports plaintext.** Dragging a file into Mail hands another app decrypted bytes.
  That is the user's explicit instruction and the whole point, but it is the one drag direction
  that leaves the encryption boundary, so it is authenticated-path only and never lazy.

## Deliberately NOT built

- **Apple Pencil / annotation.** `mvp.md` lists these as "future integration". Building a token
  annotation feature to tick a box would mean either shipping a toy that cannot round-trip an
  annotation back into an E2EE file, or building a real PDF annotation pipeline plus a
  re-encrypt-and-version-on-save flow, which is a project in its own right. Deferred, and
  recorded in `mvp.md` as deferred with this reason.
- **Stage Manager as a separate workstream.** Stage Manager is not an API. Supporting it means
  multiple scenes, no hardcoded sizes, and correct size-class response — which is exactly the
  multi-window and adaptive-layout work above. What this branch adds is the scene manifest
  declaring multi-window support and an audit that no view assumes a fixed width. Claiming
  anything more would be inventing work.
- **A chunked-secretstream format migration.** Needs backend + web agreement. Reported, not built.
- **Rewriting `FilesView`'s split view.** Extended in place, per the brief.

## Acceptance criteria

Status recorded as **verified** (a passing automated test covers the claim end to end),
**partial** (a test covers part of it), or **unverified** (nothing automated does). No box is
ticked on the strength of a skipped test, and every gap is named.

Full suite after this branch: **499 tests, 9 failures** — against a parent-branch baseline of
424 tests / 9 failures. The 9 are the same pre-existing Keychain-dependent failures
(`AuthServiceTests.test_refreshTokenIfNeeded_withFreshToken_isNoOp`,
`DownloadServiceTests.test_download_throwsNotAuthenticated_whenTokenAbsentButKeysPresent`, 3x
`KeyImportServiceTests`, 3x `KeyQRDecryptServiceTests`). **75 tests added, no new failures, and
none of the 9 was fixed by this branch.**

### Large File Streaming

- [x] **verified** — The streaming decrypt produces byte-identical output to libsodium's own
      `pull`, across sizes straddling the 64-byte block and the chunk boundary (0, 1, 63, 64,
      65, 127, 128, 129, 1000, 4095–4097, 8192, 8193, 20 000, 50 000, 16 MB).
      `SecretStreamCryptoTests.test_decryptData_matchesLibsodium_acrossBlockBoundaries`,
      `…_decryptFile_matchesLibsodium_acrossChunkBoundaries`, `…_decryptFile_andDecryptData_agree`.
- [x] **verified** — Tampering is rejected: body byte, tag byte, MAC byte, header byte, and
      wrong key each produce `authenticationFailed`. Five tests in `SecretStreamCryptoTests`.
- [x] **verified** — Fails closed: a failed decrypt leaves no plaintext on disk.
      `test_decryptFile_deletesOutputWhenAuthenticationFails`.
- [x] **verified** — Random-access decrypt of an arbitrary range equals the same span of the
      full plaintext, including unaligned offsets.
      `test_randomAccess_matchesFullDecrypt_forArbitraryRanges`.
- [x] **verified** — The loader issues correct `Range` headers, requests only the aligned span
      it needs, and **fails closed on a 200** response.
      `EncryptedMediaStreamTests.test_read_requestsOnlyTheAlignedCiphertextRange`,
      `…_prepare_throwsWhenServerIgnoresRange`, `…_read_throwsOnShortResponse`.
- [x] **verified** — Preparing a stream costs one 24-byte ranged request, not a whole-file
      fetch. `test_prepare_derivesPlaintextLengthFromContentRange`.
- [x] **verified** — The stream/download policy takes the unauthenticated path only for media
      above the threshold with a known size.
      `test_shouldStream_requiresMediaTypeAndSizeAboveThreshold`.
- [ ] **partial** — Decryption is incremental in bounded steps
      (`test_decryptFile_processesIncrementally_inBoundedSteps`), and a 16 MB file decrypts
      correctly with a 64 KB chunk. **Peak resident memory is not asserted**: the decrypt writes
      an output file whose dirty pages are charged to the process, and a measurement showed RSS
      growth of exactly the output size. The measurement cannot distinguish "buffered the input"
      from "wrote the output", so asserting on it would prove the wrong thing. Real peak
      footprint is verification doc §1.4.
- [ ] **unverified** — Video/audio playback actually begins before the whole file has been
      fetched. Requires a real `AVPlayer` decoding real media; no unit test can drive an
      `AVAssetResourceLoaderDelegate`. Verification doc §1.1–1.3.
- [ ] **unverified** — The File Provider materializes a file larger than 64 MB. Nothing in the
      test suite can drive a File Provider extension (a constraint inherited from PR #9). The
      cap was raised from 64 MB to 2 GiB on the strength of the memory fix; **the new value is a
      prudence guard, not a measured ceiling.** Verification doc §1.5.

### Smart Offline Sync

- [x] **verified** — Access records persist across instances, accumulate counts, and never
      overwrite a known size with nil. Four `SmartOfflineSyncTests` cases.
- [x] **verified** — Ranking combines frequency and recency in the intended direction (a
      habitual file beats a fresh one-off; between equals, recency wins).
      `test_tracker_scoreRewardsBothFrequencyAndRecency`, `…_rankedRecords_areOrderedByScoreDescending`.
- [x] **verified** — The cache never exceeds its budget, skips unknown-size candidates, and
      skips files larger than the whole budget without evicting anything. Four cases.
- [x] **verified** — Eviction removes the lowest-scoring managed file, never churns a
      higher-scoring one out for a lower-scoring one, and **never evicts a user-pinned file** —
      asserted both in the planner (`test_plan_neverEvictsUserPinnedFiles`) and in the mechanism
      (`test_offlineService_evictManagedRefusesToDeleteAPinnedFile`).
- [x] **verified** — Sync does not run when Wi-Fi / charging constraints are unmet, and is
      opt-in with Wi-Fi-only defaulted on. Four cases.
- [x] **verified** — The budget is recomputed from disk, not accumulated: a manifest claiming
      10 499 bytes over a 64-byte file and a missing file reports 64.
      `test_offlineService_actualManagedSizeIsRecomputedFromDisk`.
- [x] **verified** — A manifest written before `isManaged` existed decodes, and decodes as
      *pinned* (the safe reading). `test_offlineFile_decodesLegacyManifestWithoutIsManaged`.
- [ ] **unverified** — That a full pass actually downloads and caches files against a live
      server. `SmartOfflineSyncService.sync` is exercised only through its pure planner; the
      network half needs a server. Verification doc §2.
- [ ] **unverified (by design, not a gap)** — Background caching. Sync runs on foreground only;
      see "Deliberately NOT built".

### iPad

- [x] **verified** — A document window's state round-trips through `Codable`, including a nil
      MIME type, and rebuilds a viewer-capable placeholder. Four `DriveItemTransferTests` cases.
- [x] **verified** — Drag payloads advertise a correct, non-dynamic type identifier, preferring
      the filename extension over a generic `application/octet-stream`. Four cases.
- [x] **verified** — Dragging does **not** decrypt until a drop actually occurs, and the loader
      is invoked when it does. `test_makeItemProvider_doesNotDecryptUntilDropped`,
      `…_loadsFileOnlyWhenRequested`.
- [x] **verified** — Folders cannot be dragged. `test_canDrag_filesOnly`.
- [ ] **unverified** — The gestures themselves: dragging a file into Mail and getting a readable
      attachment, dropping a file from Files and getting an encrypted upload, two windows side
      by side, Stage Manager resizing. All need two running apps and a touch sequence.
      Verification doc §3.

### Roadmap

- [x] **verified by inspection** — `mvp.md` records Push Notifications, Device Registration, and
      Key Rotation as **blocked**, each naming the specific backend gap, with the grep that
      establishes it. Not an automated claim; the evidence is reproducible from the commands in
      the doc.
- [x] **verified by inspection** — `mvp.md` records the no-per-version-key finding from PR #8,
      and the two new backend findings from this branch (`quick-access` scoring never executes;
      `file_activity_log` is never written for file access).

---

## Recommended follow-up (not built here)

1. **Chunked secretstream.** The one change that would make streamed playback
   integrity-protected and let a range be authenticated independently. Requires backend + web
   agreement and a migration path for existing files; a client-only change cannot do it.
2. **Backend: fix `quick-access`.** `src/drive/priority/service.rs` groups on `al.action_type`
   where the column is `action`, and `.unwrap_or_default()` hides the error. The endpoint has
   never returned frequency-ranked results.
3. **Backend: write `file_activity_log` on file access.** Nothing logs a view or download, so
   the activity API cannot report real usage.
4. **Backend: a delta/change feed**, which is what would let the File Provider report real sync
   changes instead of `syncAnchorExpired` (inherited from PR #9).
