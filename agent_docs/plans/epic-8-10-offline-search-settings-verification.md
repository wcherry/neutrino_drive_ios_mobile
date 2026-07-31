# Manual Verification: Epics 8, 9, 10 — Offline Files, Search, Settings

## Prerequisites
- [ ] `FeatureFlags.offlineFiles` and `FeatureFlags.search` are `true` (default on this branch)
- [ ] App is built and running on an iOS 16+ simulator or device, pointed at a real backend
      (`AuthService.defaultHost` / server host setting) — this branch talks to real endpoints
      (`/api/v1/drive/search`, `/api/v1/drive/quota`), unlike earlier epics that used mock data
- [ ] You are logged in and have imported an encryption key (Settings → Import Encryption Key)
- [ ] My Drive has at least 3–4 files with distinct, easily-searchable names

---

## Steps to Verify

### Epic 8 — Offline Files

#### Happy Path: Make Available Offline
1. In My Drive, long-press (context menu) any file.
2. Confirm "Make Available Offline" appears in the menu (above Rename/Move/Delete).
3. Tap it — confirm a download/progress overlay appears briefly (reuses the existing download
   overlay).
4. Long-press the same file again — confirm the menu item now reads "Remove Offline".
5. Switch to the **Offline** tab — confirm the file now appears in the list.

#### Happy Path: Open Offline, No Network
6. Enable Airplane Mode (or otherwise disconnect the device/simulator from the network).
7. Open the **Offline** tab — confirm the previously-cached file is still listed.
8. Tap it — confirm it opens via QuickLook immediately, with no spinner, no network error.
9. Disable Airplane Mode.

#### Happy Path: Remove Offline
10. In the Offline tab, swipe left on a file and tap **Remove Offline** (or use the context
    menu).
11. Confirm the file disappears from the Offline tab.
12. Return to My Drive, long-press the same file — confirm the context menu now reads "Make
    Available Offline" again.

#### Empty State
13. With no offline files cached, open the Offline tab — confirm "No Offline Files" empty state
    with a subtitle explaining how to add one.

#### Feature Flag Off
14. Set `FeatureFlags.offlineFiles = false`, rebuild.
15. Long-press a file in My Drive — confirm "Make Available Offline" / "Remove Offline" no
    longer appears.
16. Confirm the Offline tab still shows any files cached before the flag was disabled (read path
    is unaffected).
17. Restore `offlineFiles = true` before committing.

---

### Epic 9 — Search

#### Happy Path: Search My Drive
18. Go to My Drive (root). Confirm a search field appears at the top of the list (standard
    `.searchable` UI).
19. Type part of a known file's name.
20. Confirm results update shortly after you stop typing (not on every keystroke — there should
    be a brief, barely-noticeable delay, not an update per character).
21. Confirm only files appear in results — never folders, even if a folder name matches your
    query (server-side constraint, see PR description).
22. Tap a result — confirm it opens exactly as it would from the normal My Drive list (native
    Neutrino viewer for Doc/Sheet/Slide/Diagram/Drawing, or download+QuickLook for other types).

#### No Results
23. Search for a nonsense string unlikely to match anything — confirm a "No Results" empty state
    with the query echoed back.

#### Clearing Search
24. Clear the search field — confirm the list reverts to the normal My Drive contents (not a
    lingering empty state or stale results).

#### Scope
25. Switch to Recents, Shared, or Trash — confirm no search field appears (search is My Drive
    only, per the plan).

#### Feature Flag Off
26. Set `FeatureFlags.search = false`, rebuild.
27. Go to My Drive — confirm no search field appears.
28. Restore `search = true` before committing.

---

### Epic 10 — Settings

#### Storage
29. Open the **Settings** tab.
30. Confirm a "Storage" section appears showing used space (e.g. "12.3 MB of 5 GB used") with a
    progress bar beneath it.
31. If your account has no quota configured server-side, confirm the text instead reads
    "X used of Unlimited" with no progress bar (divide-by-zero / nil-quota case).

#### Cache
32. Confirm a "Cache" section shows "Offline Cache: <size>" reflecting the files cached in
    Epic 8's flow above.
33. With at least one offline file cached, tap "Clear Offline Cache" — confirm a confirmation
    dialog appears before anything is deleted.
34. Confirm the button is disabled when there are no offline files cached.
35. Confirm — after confirming the dialog — the Offline tab is now empty and the Cache section
    shows 0 bytes.

#### Sync Status
36. Confirm a "Sync" section shows "All changes synced" under normal conditions.
37. Trigger a `DriveService` error (e.g. disconnect network and pull-to-refresh / navigate into
    a folder) — confirm the Sync row reflects an error state instead (red text/icon).

#### Existing Sections Unaffected
38. Confirm "Encryption Key" (Key status / Remove Keys) and "Sign Out" still work exactly as
    before — this branch must not have regressed them.

---

## Expected Results

| Step | Expected |
|------|----------|
| Step 3–5 | File downloads, appears in Offline tab |
| Step 8 | Offline file opens with zero network activity |
| Step 11–12 | Remove Offline clears both the Offline tab and My Drive's menu state |
| Step 13 | Offline empty state shown |
| Step 20–21 | Debounced search, files only, never folders |
| Step 23–24 | No Results state / reverts cleanly when cleared |
| Step 30–31 | Quota shown as used/total or used/Unlimited |
| Step 33–35 | Clear Cache confirms, then empties Offline tab and cache size |
| Step 36–37 | Sync status reflects DriveService state |

---

## Known Limitations (by design, not bugs)
- Search only returns files, never folders — the backend's `/api/v1/drive/search` endpoint has
  no folder-search implementation (confirmed by reading `service.rs`). See PR description.
- Deleting/trashing a file in My Drive does not automatically remove it from the offline cache —
  out of scope for this epic.
- Sync status is a lightweight derived indicator, not a real background-sync engine — there is
  none in this codebase yet.

## Rollback
Disable `FeatureFlags.offlineFiles` and/or `FeatureFlags.search` (set to `false`) for an instant,
no-deployment rollback of the write paths for those two epics. Settings' Storage/Cache/Sync
sections are unflagged (matching Key status/Logout); reverting them requires reverting the branch.
