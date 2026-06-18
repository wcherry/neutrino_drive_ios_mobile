# Manual Verification: Epic 4 — File Browser

## Prerequisites
- [ ] Feature flag `FeatureFlags.fileBrowser` is `true` (it is by default on this branch)
- [ ] App is built and running on an iOS 16+ simulator or device
- [ ] You are logged in (or `authService.isAuthenticated` is forced to `true` in preview/simulator)

---

## Steps to Verify

### Happy Path: Browse My Drive

1. Launch the app and tap the **Files** tab.
2. On iPhone: confirm a segmented picker with "My Drive / Shared / Recents / Trash" appears in the navigation bar.
3. Confirm the My Drive section shows 4 root folders: Documents, Photos, Projects, Archive.
4. Tap **Documents** — confirm it navigates into the folder and shows Q3 Report.pdf and Meeting Notes.txt.
5. Tap the back button — confirm you return to the root of My Drive.

### Happy Path: Create Folder

6. From the My Drive root, tap the **folder+** button in the top-right toolbar.
7. Confirm the "New Folder" sheet appears with an empty text field.
8. Enter a name (e.g. "Test Folder") and tap **Create**.
9. Confirm "Test Folder" appears in the My Drive root list.
10. Verify the **Create** button is disabled when the name field is empty.
11. Tap **Cancel** — confirm the sheet dismisses without adding a folder.

### Happy Path: Rename

12. On any item in My Drive, swipe right to reveal the **Rename** action.
13. Tap Rename — confirm the Rename sheet appears pre-filled with the current name.
14. Change the name and tap **Save**.
15. Confirm the new name is reflected in the list immediately.
16. Verify the **Save** button is disabled when the name is unchanged or empty.

### Happy Path: Delete (Move to Trash)

17. On any item in My Drive, swipe left to reveal the **Delete** action.
18. Tap Delete — confirm the item disappears from My Drive.
19. Switch to the **Trash** section — confirm the deleted item appears there.

### Happy Path: Restore from Trash

20. In the Trash section, swipe right on the deleted item to reveal **Restore**.
21. Tap Restore — confirm the item disappears from Trash.
22. Switch back to My Drive — confirm the item has returned to its original folder.

### Happy Path: Permanent Delete from Trash

23. In the Trash section, swipe left on an item to reveal **Delete Forever**.
24. Tap Delete Forever — confirm the item is permanently removed (does not appear in My Drive).

### Happy Path: Empty Trash

25. Delete at least one item from My Drive (so Trash is non-empty).
26. Switch to the Trash section — confirm the **Empty Trash** button is visible in the toolbar.
27. Tap **Empty Trash** — confirm a confirmation dialog appears.
28. Confirm the action — verify the Trash section is now empty.
29. Verify the **Empty Trash** button is disabled when Trash is already empty.

### Happy Path: Move

30. Long-press (context menu) on a file in My Drive and select **Move**.
31. Confirm the Move sheet lists all non-trashed folders except descendants.
32. Select a different folder and tap **Move**.
33. Confirm the file now appears in the target folder and is absent from the original folder.
34. Verify the **Move** button is disabled when the currently selected destination is the same as the current parent.

### Shared Section

35. Switch to **Shared** — confirm Meeting Notes.txt and Demo.mp4 appear (they are the shared mock items).
36. Attempt to swipe — confirm no swipe actions are available (read-only).

### Recents Section

37. Switch to **Recents** — confirm a list of recently modified items appears, sorted newest first.
38. Attempt to swipe — confirm no swipe actions are available (read-only).

### Empty States

39. Empty the Trash, then switch to Trash — confirm the empty state message "Trash is Empty" and a trash icon appear.
40. (If all shared items are deleted) Switch to Shared — confirm the "Nothing Shared Yet" empty state appears.

### iPad Layout (if iPad simulator available)

41. Run on an iPad simulator.
42. Confirm a `NavigationSplitView` appears with a sidebar listing the four sections.
43. Tap each section in the sidebar — confirm the detail column updates accordingly.

---

## Edge Cases

### Cycle Prevention (Move)

44. Navigate into Documents and create a nested sub-folder (e.g. "Sub").
45. Long-press on Documents (or a parent folder) and open Move.
46. Confirm the "Sub" folder is **not** listed as an eligible destination (it is a descendant).

### Rename Validation

47. Open Rename on any item.
48. Clear the name field — confirm **Save** is disabled.
49. Restore the original name exactly — confirm **Save** is disabled.

---

## Feature Flag Off

50. In `FeatureFlags.swift` set `fileBrowser = false` and rebuild.
51. Tap the Files tab — confirm the old placeholder ("Files" large title, centered) is shown instead of the full browser.
52. Restore `fileBrowser = true` before committing.

---

## Expected Results

| Step | Expected |
|------|----------|
| Step 2 | Segmented picker with 4 sections |
| Step 3 | 4 root folders visible |
| Step 9 | New folder appears in list |
| Step 15 | Renamed item shows new name |
| Step 18 | Item disappears from My Drive |
| Step 19 | Item appears in Trash |
| Step 21 | Item disappears from Trash |
| Step 22 | Item reappears in My Drive |
| Step 28 | Trash is empty |
| Step 32 | Move sheet lists folders |
| Step 33 | File appears in new folder |
| Step 51 | Legacy placeholder shown |

---

## Rollback

Disable `FeatureFlags.fileBrowser` (set to `false`) — instant rollback, no deployment required.
The Files tab will fall back to the original placeholder with no side effects.
