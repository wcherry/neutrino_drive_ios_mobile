# Implementation Plan: Epic 4 — File Browser

## Branch
`feature/epic-4-file-browser`

## What is Changing and Why
Epic 4 adds the core drive experience: a full file browser that lets authenticated
users navigate their files and folders, perform CRUD operations on them, and switch
between four sections (My Drive, Shared, Recent, Trash). This replaces the current
placeholder `FilesView.swift`.

## Architecture Summary (following existing patterns)

### Existing Patterns Observed
- SwiftUI + MVVM-lite: `ObservableObject` view models with `@Published` state, consumed
  via `@StateObject` / `@ObservedObject` in Views.
- Services are plain `enum` (stateless) or `@MainActor final class ObservableObject`.
- `AuthService` is `@EnvironmentObject` injected at the root. Other services are either
  singletons (`KeychainService`) or state held inside views.
- All views inside the Files tab already have `NavigationStack` wrapping from `ContentView`.
- Mock data is acceptable — no real backend in this dev environment.
- Error handling uses `LocalizedError` enums matching the `AuthError` / `KeyImportError`
  pattern.

### New Files to Create

#### Models (NeutrinoDrive/Models/)
- `DriveItem.swift` — `struct DriveItem: Identifiable, Hashable` with id, name, type
  (folder / file), parent, size, modifiedAt, isTrashed, isShared, iconName helper.
- `DriveSection.swift` — `enum DriveSection` (myDrive, shared, recents, trash) used
  by the file-browser sidebar / segmented control.

#### Services (NeutrinoDrive/Services/)
- `DriveService.swift` — `@MainActor final class DriveService: ObservableObject`.
  Owns in-memory mock data for all sections. Exposes:
  - `func items(in section: DriveSection, parentID: String?) -> [DriveItem]`
  - `func createFolder(name: String, parentID: String?, in section: DriveSection)`
  - `func rename(item: DriveItem, to newName: String)`
  - `func delete(item: DriveItem)` (moves to Trash unless already in Trash)
  - `func move(item: DriveItem, to newParentID: String?)`
  - `func restore(item: DriveItem)` (moves from Trash back to My Drive)
  - `func emptyTrash()`

#### Views (NeutrinoDrive/Views/)
- `FilesView.swift` (replace existing stub) — Root Files tab view.
  - iPhone: `NavigationStack` with section picker (segmented or navigation sidebar).
    Displays `FileBrowserView` for the selected section.
  - iPad: `NavigationSplitView` with sidebar listing sections and a detail column.
- `FileBrowserView.swift` — shows the list of items for a given section + parentID.
  - `List` with swipe-to-delete and context menus for rename / move.
  - Toolbar: "New Folder" button (in My Drive only).
  - Handles empty state.
  - Navigates into sub-folders by pushing another `FileBrowserView`.
- `FileRowView.swift` — A single row: icon, name, metadata (size / date), chevron for folders.
- `CreateFolderSheet.swift` — Modal sheet with a text field and Create / Cancel.
- `RenameSheet.swift` — Modal sheet pre-filled with current name.
- `MoveSheet.swift` — Folder picker sheet for choosing a destination parent folder.

#### Config (NeutrinoDrive/Config/)
- `FeatureFlags.swift` (update) — add `static let fileBrowser: Bool = true`.

#### Tests (NeutrinoDriveTests/)
- `DriveServiceTests.swift` — unit tests for all DriveService mutations.
- `DriveItemTests.swift` — tests for model helpers (icon names, type classification).

## Layers Affected
- **Frontend / UI:** FilesView (replace stub), FileBrowserView, FileRowView, CreateFolderSheet,
  RenameSheet, MoveSheet, DriveSection picker.
- **Service layer:** DriveService (mock in-memory).
- **Models:** DriveItem, DriveSection.
- **Feature flag:** `FeatureFlags.fileBrowser`.
- **Tests:** DriveServiceTests, DriveItemTests.

## Feature Flag
- Name: `feature.fileBrowser` (represented as `FeatureFlags.fileBrowser: Bool`)
- Default: **off** in source, set to `true` in this branch so the feature is testable.
  When `false`, `FilesView` falls back to its current placeholder.

## iPhone / iPad Layout
- iPhone: `NavigationStack` with a `Picker` segmented control in the toolbar to switch
  sections. Sub-folder navigation pushes onto the stack.
- iPad: `NavigationSplitView` with a sidebar listing the four sections; detail column
  shows `FileBrowserView`.

## Known Risks and Edge Cases
- Moving a folder into one of its own descendants must be prevented.
- Trash section: rename, create folder, and move are disabled; only restore and
  permanent delete are available.
- Recents section: read-only (no mutations from this section, user must navigate to the
  item's parent).
- Shared section: read-only in this epic (full sharing is a later epic).
- Empty root of My Drive should show an empty-state illustration.

## Acceptance Criteria
1. Files tab shows a browseable list of mock files and folders.
2. User can navigate into sub-folders (breadcrumb or back button works).
3. User can create a new folder in My Drive.
4. User can rename any item in My Drive.
5. User can delete any item (moves to Trash).
6. User can move an item to another folder in My Drive.
7. Trash section shows deleted items; user can restore or permanently delete them.
8. Recent section shows recently modified items (read-only).
9. Shared section shows shared items (read-only).
10. Feature flag `FeatureFlags.fileBrowser = false` shows the old placeholder.
11. Layout is sensible on both iPhone and iPad.
12. All unit tests pass.
