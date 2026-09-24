# Plan: Photo capture dates, and an upload key that survives suspension

## Summary

Two defects in the Drive iOS upload path, both silent and both permanent once they happen.

**Issue #31** — photo auto-sync never sends a capture date, so every backed-up photo is dated
by the upload run. The server stamps `created_at`/`updated_at` with its own clock and the
client had no second call to correct them, even though `PATCH /drive/files/{id}/import-metadata`
has existed since `wcherry/neutrino` #110. A year of camera roll lands on one afternoon.

**Issue #33** — `E2EEUploader` commits a file in two steps on two different URLSessions: the
ciphertext on the background session (designed to survive suspension) and the sealed DEK on the
foreground one (which does not). Suspended between the two, the blob commits, the row declares
itself encrypted, and the only copy of the DEK — held in memory since step 2 — goes away with
the process. The file is undecryptable by every client, forever.

## Affected Repos

- `neutrino_drive_ios_mobile` — all of it. Both fixes are client-side.

Explicitly **not** changed:

- `neutrino` — the `import-metadata` endpoint #31 needs already exists and is unchanged.
  Direction 3 of #33 (carry the sealed key in the multipart upload so blob and key commit
  atomically) would be a server change plus every client; it is the real fix and is left as a
  follow-up, noted below.
- `neutrino_photos_ios_mobile` — issue #31's "Related, not fixed by this" note. Photos sends
  `captureDate` to `POST /photos` so its timeline is right, but never patches the underlying
  Drive file. Worth a matching change once this pattern is settled.

## Tasks

### Issue #31 — capture dates

1. `PhotoSyncQueue.completed` becomes `[String: CompletedUpload]` (localIdentifier → file id)
   with a hand-written `init(from:)` that decodes the old bare-`Set<String>` form. Legacy
   entries decode with a nil file id, which is honest: they completed before the ledger kept
   one.
2. `PhotoSyncQueue.Entry` carries `modificationDate`. `PhotoAssetProviding` grows
   `modificationDate` alongside `creationDate`; `PHAsset` already has it.
3. `uploadWithFolderRetry` keeps the `UploadResult` instead of discarding it, and records the
   file id with the completion.
4. A second call after the content: `PATCH /drive/files/{id}/import-metadata` with
   `createdAt` = capture date, `updatedAt` = modification date (falling back to creation),
   `importSource` = `photo-sync:<localIdentifier>`. It has to be second — writing the body is
   what stamps `updated_at`.
5. A failed patch warns and moves on. The photo is already safe; failing the entry would
   re-upload a good file.
6. `DriveService.setImportMetadata` sends it, with RFC 3339 timestamps —
   `parse_import_timestamp` on the server is strict about a shape it cannot read.

### Issue #31 — repairing photos already uploaded

7. "Repair Photo Dates", a one-time pass in Settings → Photo Sync, on `PhotoSyncService` (it
   already owns the queue, the destination folder and the constraints).
8. Page the destination folder by name, build a filename → asset index from the device for
   every identifier in `completed`, and patch each unique match.
9. Ambiguous filenames (one name, several assets) are counted and left alone rather than
   guessed at.
10. Report plainly: repaired / already correct / ambiguous / not on this device / failed.

### Issue #33 — a DEK that outlives the process

11. `PendingUploadKeyStore`: the sealed DEK, its key version and the file id, written to the
    App Group container *before* the blob goes out and removed once the key `PUT` lands. The
    DEK is already sealed to the user's own public key at that point, so it is safe at rest.
    In the App Group rather than the app container so the host app can reconcile an upload the
    share extension started.
12. `E2EEUploader.upload` takes an `uploadID` — a stable identity for one logical transfer —
    and passes `upload-<uploadID>` as the transfer id, so `BackgroundTransferService`'s
    existing `claimOrphanedResult` can finally fire on this path (it defaulted to a fresh UUID
    per attempt, which can never match).
13. A retry that finds a stored record **reuses its DEK** rather than generating a new one.
    Without this, #12 makes things worse: the orphan-claim returns the old blob's response
    while the ciphertext was re-encrypted under a fresh key, and the key stored would not open
    the bytes on the server.
14. A retry whose record already carries a file id skips the blob `POST` entirely and reads the
    file's metadata back, so a killed process cannot turn into a duplicate upload.
15. `reconcilePendingKeys()` at launch and on foreground: retry the `PUT` for every record that
    has a file id. Records with no file id are pruned after 30 days.
16. Photo sync passes `photo-sync:<localIdentifier>` as its upload id — stable across retries
    of the same asset, which is what makes #12–#14 reachable for the path that suspends most.

## Test Plan

- Unit (`PhotoSyncQueueTests`): the legacy `Set` form decodes; a completion records its file id;
  compaction keeps the mapping.
- Unit (`PhotoSyncServiceTests`): the stamp carries the capture date and the `photo-sync:`
  source; a failing stamp leaves the entry completed rather than failed; the file id reaches
  the ledger.
- Unit (`PhotoDateRepairTests`): the planner's four outcomes, and a full pass over fakes.
- Unit (`PendingUploadKeyStoreTests`): record / attach / remove / prune / reload.
- Unit (`E2EEUploaderTests`): the record exists while the blob is in flight and is gone after
  the key `PUT`; a failed `PUT` leaves it with the file id; a resumed record with a file id
  posts no blob; reconciliation retries and clears.
- E2E: none. Both defects are in an iOS client the Playwright suite does not drive.

## Feature Flag

None. Both are bug fixes to an existing path, and the way to disable either is to revert.

## Known gaps, stated up front

- The repair pass skips a file by comparing the server's `createdAt` to the matched asset's
  capture date, not by reading `importSource` as issue #31 suggested. The folder-contents DTO
  (`FileResponse`) does not carry `import_source` — only `FileMetadataResponse` does — so
  reading it would mean one extra request per photo. The date comparison is free, is the
  property actually wanted, and is equally idempotent.
- A photo whose name the server had to disambiguate on upload (`IMG_0001 (1).HEIC`) will not
  match its asset and is reported as not found on this device.
- Photos deleted from the device, uploaded from another device, or uploaded before a reinstall
  have no local asset and keep their wrong dates. Reading `DateTimeOriginal` back out of the
  decrypted file is correct but expensive; it belongs behind an explicit per-file action.
- #33 direction 3 — one atomic request — is not done here. The window is now narrow and
  recoverable rather than closed.

## Open Questions

None blocking. `import_source` is reused with a `photo-sync:` prefix, as issue #31 recommends,
rather than adding a provenance field to the backend.
