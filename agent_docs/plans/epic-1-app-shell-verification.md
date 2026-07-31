# Manual Verification: Epic 1 — Mobile Application Shell

## Prerequisites

- Xcode 15+ installed
- iOS 16+ simulator available
- Source files from `epic/1-app-shell` branch checked out

## Setup

1. Open Xcode.
2. Create a new iOS App project: File > New > Project > iOS > App.
3. Set Product Name to `NeutrinoDrive`, Bundle Identifier to `com.neutrino.drive`, Interface to SwiftUI, Language to Swift, minimum deployment to iOS 16.
4. In the project navigator, delete the auto-generated `ContentView.swift` and `NeutrinoDriveApp.swift`.
5. Right-click the project root > Add Files to "NeutrinoDrive" > select all files from `NeutrinoDrive/` in this repo (including the `Views/` subfolder). Ensure "Copy items if needed" is unchecked if the repo is already in a local path.
6. Build and run on any iOS 16+ simulator.

## Steps to Verify

### Happy Path

1. Launch the app in the simulator.
2. Confirm the tab bar shows four tabs at the bottom: Files, Recents, Offline, Settings.
3. Confirm each tab has the correct icon:
   - Files: folder icon
   - Recents: clock icon
   - Offline: arrow pointing into a circle (arrow.down.circle)
   - Settings: gear icon
4. Tap the Files tab — verify "Files" appears as the navigation title and "Files" text is centered in the view.
5. Tap the Recents tab — verify "Recents" navigation title and centered text.
6. Tap the Offline tab — verify "Offline" navigation title and centered text.
7. Tap the Settings tab — verify "Settings" navigation title and centered text.
8. Switch between tabs multiple times to confirm navigation state is preserved per tab (each tab retains its own navigation stack).

### Edge Cases

1. Rotate the device to landscape — confirm tab bar and content layout remain usable.
2. On iPad (if tested), confirm the tab bar is present and functional.

## Expected Results

- Four tabs visible immediately on launch with correct icons and labels.
- Each tab shows its name as both the navigation bar title and as centered body text.
- No crashes on tab switching or rotation.

## Rollback

No feature flag is used for this epic — it is the entire app shell. To roll back, revert to the `main` branch (which currently has no source code).
