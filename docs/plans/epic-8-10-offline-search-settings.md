# Implementation Plan: Epics 8, 9, 10 — Offline Files, Search, Settings

## Branch
`feature/epic-8-10-offline-search-settings`

## What is Changing and Why
Three MVP epics are bundled onto one branch/PR at the user's explicit request:

- **Epic 8 (Offline Files):** let a user mark a My Drive file "Available Offline" so it is
  downloaded, decrypted, and persisted to durable local storage; the Offline tab lists and
  opens these files without any network call.
- **Epic 9 (Search):** search My Drive file names via the real server-side metadata search
  endpoint (`GET /api/v1/drive/search`), surfaced through `.searchable()` on the My Drive list.
- **Epic 10 (Settings):** extend the existing Settings screen (which already has Key status
  and Logout, both unflagged) with Storage usage (quota endpoint), Cache size (offline cache
  directory size), and Sync status (derived from `DriveService.isLoading` / `.error`).

## Real Backend Contracts (ground truth, read from sibling backend repo source)

### Search — `GET /api/v1/drive/search`
Query params: `q` (required), `fileType`, `ownerId`, `after`, `before`, `sharedOnly` (default
false), `limit` (default 20), `offset` (default 0).
Response (camelCase):
```json
{ "items": [{ "id", "name", "mimeType", "sizeBytes", "createdAt", "updatedAt", "userId", "snippet" }], "total": 3 }
```
**Constraint:** this endpoint only ever returns files — the backend's `service.rs` queries the
`files` table by name only; there is no folder search implemented server-side. Mobile search
is therefore file-name search only. This is a documented deviation from the epic text ("File
names, Folder names") — called out in the PR description, not silently dropped.

### Storage quota — `GET /api/v1/drive/quota`
Response (camelCase): `{ "usedBytes", "dailyUploadBytes", "quotaBytes", "dailyCapBytes" }`.
`quotaBytes` and `dailyCapBytes` are nullable (null = unlimited). No `dailyResetAt` field (a
stale web TypeScript type has one; the Rust struct — ground truth — does not).

Both endpoints use the same Bearer-token pattern as `DriveService.authorized()`.

## Existing Patterns To Follow
- Each service is a standalone `@MainActor final class ... ObservableObject` with its own
  `LocalizedError` enum, its own `os.log` Logger, and its own private snake_case-tolerant
  `JSONDecoder` + get/post HTTP helpers — no shared networking base class (see `DriveService`,
  `DownloadService`, `UploadService`). New services follow the same shape.
- `FeatureFlags` — one `static let xxx: Bool = true` per epic with a doc comment.
- Views gate optional UI behind `FeatureFlags.xxx` checks, matching `FileBrowserView`'s
  `FeatureFlags.downloadFiles` / `FeatureFlags.viewNeutrinoFiles` pattern.
- No CoreData/SwiftData anywhere in this codebase — persistence is Keychain (secrets) or plain
  files/UserDefaults (everything else). The offline manifest follows suit: a JSON file.

## New Files

### Models
- `NeutrinoDrive/Models/OfflineFile.swift` — `struct OfflineFile: Identifiable, Codable`:
  `id`, `name`, `mimeType`, `sizeBytes`, `localURL` (stored as relative path, resolved against
  the offline directory at read time so it survives app container path changes across
  installs/updates), `cachedAt: Date`.

### Services
- `NeutrinoDrive/Services/OfflineService.swift` — `@MainActor final class OfflineService:
  ObservableObject`.
  - `@Published private(set) var offlineFiles: [OfflineFile] = []`
  - `func isOffline(fileID: String) -> Bool`
  - `func makeAvailableOffline(item: DriveItem, downloadService: DownloadService) async throws`
    — calls `DownloadService.download(fileID:fileName:mimeType:)` to get a decrypted temp URL,
    copies it into `Application Support/OfflineFiles/<fileID>/<fileName>`, updates the
    manifest, persists it.
  - `func removeOffline(fileID: String)` — deletes the file + manifest entry.
  - `func cacheSizeBytes() -> Int64` — sums `sizeBytes` across the manifest (falls back to
    `FileManager` attributes if the manifest doesn't have it).
  - Manifest persisted as JSON at `Application Support/OfflineFiles/manifest.json`, loaded on
    `init()`.
  - Own `OfflineError: LocalizedError` (`downloadFailed`, `fileWriteError`, `manifestError`).
- `NeutrinoDrive/Services/SearchService.swift` — `@MainActor final class SearchService:
  ObservableObject`.
  - `@Published var results: [DriveItem] = []`, `@Published var isSearching = false`,
    `@Published var error: String?`
  - `func search(query: String) async` — builds the query string (`q` + percent-encoding),
    calls `GET /api/v1/drive/search`, maps `APISearchItem` → `DriveItem` (folders never
    appear; `type` is always `.file`).
  - Own `SearchError: LocalizedError`, own decoder (matches `DriveService`'s two-date-format
    custom strategy), own private get helper reusing the `authorized()`-style Bearer injection
    (duplicated per existing convention, not shared).
- `NeutrinoDrive/Services/QuotaService.swift` — `@MainActor final class QuotaService:
  ObservableObject`.
  - `@Published private(set) var quota: StorageQuota?`, `@Published var isLoading = false`
  - `func refresh() async` — `GET /api/v1/drive/quota`, decodes into `StorageQuota { usedBytes:
    Int64, quotaBytes: Int64? }` (dailyUploadBytes/dailyCapBytes decoded but not surfaced in
    Settings UI, out of scope for Epic 10's stated deliverables).

### Views
- `NeutrinoDrive/Views/OfflineView.swift` (replace placeholder) — list of `OfflineFile` via
  `FileRowView`-compatible rendering (constructs a `DriveItem` from `OfflineFile` for reuse),
  tap opens with `QuickLook` directly from the local URL (no download), swipe-to-remove calls
  `OfflineService.removeOffline`. Empty state matches existing tone ("No Offline Files" /
  "Files you mark available offline will appear here.").
- `NeutrinoDrive/Views/FileBrowserView.swift` (update) — add `.searchable(text:)` to the
  My Drive list, gated by `FeatureFlags.search`; `.task(id: searchText)` debounced (300ms
  `Task.sleep`) calling `SearchService.search`; when `searchText` non-empty, list switches to
  search results instead of `currentItems`; tapping a result reuses the existing
  `fileRow(for:)` branching (native viewer vs download vs disabled). Also add "Make Available
  Offline" / "Remove Offline" to `contextMenuItems(for:)` for `.myDrive` files, gated by
  `FeatureFlags.offlineFiles`.
- `NeutrinoDrive/Views/SettingsView.swift` (update) — new "Storage" section: usage text (`used
  / quota` via `ByteCountFormatter`, or "used of Unlimited" when `quotaBytes == nil`) with a
  `ProgressView(value:)` bar when quota is known; "Cache" section: cache size + a "Clear
  Offline Cache" destructive button; "Sync" section: static row showing "All changes synced"
  or "Sync error" derived from `driveService.error`. All unflagged (Epic 10 ships like
  Epics 1/2/Key-status/Logout).

### Config
- `NeutrinoDrive/Config/FeatureFlags.swift` — add `offlineFiles` (Epic 8) and `search`
  (Epic 9).

### Tests (NeutrinoDriveTests/)
- `SearchServiceTests.swift` — query-string building (encoding, defaults), response decoding
  (items → DriveItem mapping, `type == .file` always, `total` ignored in list state), error
  paths.
- `OfflineServiceTests.swift` — manifest add/remove/list, `isOffline` lookup, `cacheSizeBytes`
  summation, empty-manifest behavior. Uses a temp directory override (constructor injection or
  `#if DEBUG` seed init, matching `DriveService`'s `#if DEBUG` convenience init pattern) so
  tests don't touch the real Application Support directory.
- `QuotaServiceTests.swift` — decoding with `quotaBytes: null` (unlimited) and with a numeric
  quota.

## Layers Affected
- **Services:** OfflineService (new), SearchService (new), QuotaService (new).
- **Models:** OfflineFile (new).
- **Views:** OfflineView (replaced), FileBrowserView (search + offline context menu),
  SettingsView (storage/cache/sync sections).
- **Config:** FeatureFlags (+2 flags).
- **Tests:** 3 new test files.
- **Xcode project:** `project.yml` uses `sources: - path: NeutrinoDrive` /
  `- path: NeutrinoDriveTests` (directory globs), so `xcodegen generate` picks up new files
  automatically — no manual `project.pbxproj` surgery needed, but I will run `xcodegen
  generate` and diff `project.pbxproj` to confirm every new file landed in the right target,
  and confirm `DEVELOPMENT_TEAM: 46KWJJ63FU` in `project.yml`/generated project is untouched
  (hard project rule — never wipe that value).

## Feature Flags
- `FeatureFlags.offlineFiles: Bool = true` (Epic 8) — gates the "Make Available Offline"
  context menu item; when `false`, Offline tab still exists but shows only previously-cached
  files with no way to add new ones (harmless — matches "flag gates the write path" pattern
  used by `viewNeutrinoFiles`/`downloadFiles`).
- `FeatureFlags.search: Bool = true` (Epic 9) — gates `.searchable()` on My Drive.
- Epic 10 additions are unflagged, consistent with existing Key status / Logout sections.

## Known Risks and Edge Cases
- Offline storage location must be `Application Support` (or Documents), **not**
  `temporaryDirectory` — iOS can purge temp at any time, defeating "available with no
  network" later.
- Manifest corruption / missing file on disk (e.g. user deleted the app's storage out of
  band) — `OfflineView` should tolerate a manifest entry whose `localURL` no longer resolves
  (skip it / show a "missing" state) rather than crashing.
- Removing a file from My Drive (trash/delete) does not currently cascade to the offline
  cache — out of scope for this epic; documented as a known limitation, not fixed here.
- Search debounce: avoid firing a request per keystroke; `.task(id: searchText)` cancellation
  semantics already handle superseding a stale in-flight search when text changes again.
- Empty search query should clear results (not call the endpoint with `q=""`).
- Quota `quotaBytes: null` → render "Unlimited", not divide-by-zero.
- Cache size and quota "used" are two different numbers (local cache vs. server-side account
  usage) — Settings must not conflate them; label each explicitly.
- Search only ever returns files (server constraint) — folder rows must never appear in
  results, and this must be called out as a scope deviation, not silently implemented as if
  it worked.

## Acceptance Criteria
1. Long-press (context menu) a file in My Drive → "Make Available Offline" downloads,
   decrypts, and persists it; menu item flips to "Remove Offline" once cached.
2. Offline tab lists all cached files; tapping one opens it via QuickLook with no network
   call (airplane mode works).
3. Swiping/removing an item from the Offline tab deletes the local copy and manifest entry.
4. My Drive search field returns matching files from the live `/api/v1/drive/search`
   endpoint; folders never appear in results; tapping a result opens it exactly like a normal
   file row.
5. Settings shows Storage usage (used/quota or used/Unlimited), Cache size (human-readable),
   and Sync status, alongside the existing Key status and Logout sections.
6. `FeatureFlags.offlineFiles = false` hides the offline context-menu action;
   `FeatureFlags.search = false` hides the search field.
7. All new unit tests pass; full existing suite still passes.
8. Project builds clean via `xcodebuild`; `project.pbxproj` includes every new file in the
   correct target(s); `DEVELOPMENT_TEAM` unchanged.
