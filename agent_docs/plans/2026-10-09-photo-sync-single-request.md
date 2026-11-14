# Plan: Photo sync, one self-contained request per photo (#38, Phase 1)

## Summary
Photo sync moved about one photo per background wake-up: the drain awaited each transfer
before preparing the next, and each photo needed a key `PUT` and a date `PATCH` after its body
landed, so the app had to be awake after every transfer. The upload body now carries the
sealed key and the dates, and the drain prepares photos one at a time but hands up to 12 to the
background `URLSession` at once. Research and decisions:
`agent_docs/research/2026-10-09-photo-sync-latency.md`.

## Affected Repos
- `neutrino`: `POST /drive/files/upload` accepts `encrypted_file_key`, `key_version`,
  `created_at`, `updated_at` and `import_source` (same branch name, already committed).
- `neutrino_drive_ios_mobile`: this change.

## Tasks
1. `E2EEUploader`: split `upload` into `prepare` (encrypt, seal, record the pending key, write a
   complete body) and `submit` (send, then finish from the pending-key record). The body carries
   the key and optional `DriveImportMetadata`. `earlierUpload` / `hasEarlierUpload` collect a
   committed, running or finished-while-suspended attempt. `DriveImportMetadata` moved here so
   the share extension compiles it.
2. `BackgroundTransferService`: reattach to a task an earlier process left running
   (`resume`, `hasTransfer`), and `setOrphanHandler` to report results that land with nobody
   waiting, including ones that landed before a handler was set.
3. `PhotoSyncService`: replace the `uploadHandler` seam with `uploadPreparer` and
   `earlierUploadCollector`. The drain prepares serially, keeps up to `maxTransfersInFlight`
   transfers, and parks until one finishes. A drain requested while one runs wakes it and is
   rerun afterwards. `collectFinishedTransfer` records relaunch deliveries and tops up the
   queue. A `BGTask` drain releases its task once everything is handed off. Prepared requests
   carry `allowsExpensiveNetworkAccess = !wifiOnly`.
4. Fallbacks for an older server: when the upload response does not echo `importSource`,
   `E2EEUploader` still `PUT`s the key (an upsert) and photo sync still `PATCH`es the dates.

## Decisions
- "The server stored the extras" is detected by the response echoing `importSource`. An older
  server ignores unknown multipart fields and returns `importSource: null` for a fresh upload.
  No new response field was needed.
- The published-key lookup is not batched explicitly: `DeviceKeyCheck` already caches it for
  10 minutes, so a batch costs one request.
- In-flight cap 12: bounds temp-file disk use, and keeps late transfers inside the 15-minute
  token lifetime. A 401 costs no attempt; the photo is prepared again with a fresh token.
- `orphanedResults` stays in memory (research decision 3). The orphan handler is what makes
  that safe: results are recorded in the process they are delivered to. The existing
  launch-time catch-up scan covers photos missed while the process was dead.

## Known limitations
- Prepared requests carry the bearer token they were prepared with. A transfer that iOS
  starts more than 15 minutes later is refused with 401 and prepared again.
- A transfer re-sent under a fresh DEK after its original key became unopenable uses a
  one-off transfer id, so a relaunch cannot reattach to it (unchanged from before).

## Test Plan
- `PhotoSyncServiceTests`: pipelining (more than one in flight; never over the cap),
  expiry, a background drain returning once everything is handed off, collecting earlier
  uploads without exporting, relaunch collection, Wi-Fi-only flag on the request, dates sent
  with the upload, and no `PATCH` when the server echoed them.
- `E2EEUploaderTests`: key and dates in the body before the file part, UTC timestamps, no
  `PUT` when echoed, `PUT` when not, prepared request network flags.
- Manual: `VERIFY.md`, "photo sync latency, Phase 1".
