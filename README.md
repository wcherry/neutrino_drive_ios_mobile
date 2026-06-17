# Neutrino Drive iOS

A secure mobile file browser for Neutrino Drive encrypted cloud storage. Built with SwiftUI, the app provides end-to-end encrypted file management, offline access, and a native iOS experience.

## Tech Stack

- Swift
- SwiftUI
- iOS 16+
- Xcode

## MVP Epic Status

| Epic | Description | Status |
|------|-------------|--------|
| Epic 1 | Mobile Application Shell | COMPLETE |
| Epic 2 | Authentication | Pending |
| Epic 3 | Key Import | Pending |
| Epic 4 | File Browser | Pending |
| Epic 5 | Upload Files | Pending |
| Epic 6 | Download Files | Pending |
| Epic 7 | File Viewers | Pending |
| Epic 8 | Offline Files | Pending |
| Epic 9 | Search | Pending |
| Epic 10 | Settings | Pending |

## Getting Started

No `.xcodeproj` file is included in this repository. To open the project in Xcode:

1. Open Xcode and create a new iOS App project.
2. Name the project `NeutrinoDrive` with bundle identifier `com.neutrino.drive`, targeting iOS 16+.
3. Delete the auto-generated source files Xcode creates (e.g. `ContentView.swift`, `NeutrinoDriveApp.swift`).
4. Add the files from the `NeutrinoDrive/` directory to the project via File > Add Files to "NeutrinoDrive".

## Architecture

The app is structured as a four-tab SwiftUI shell with tabs for Files, Recents, Offline, and Settings. Each tab is wrapped in a `NavigationStack` at the root `ContentView` level, keeping navigation state independent per tab. Future epics will layer in authentication, encryption key management, file browsing backed by the Neutrino Drive API, upload and download workflows, offline file caching, and full-text search across the user's stored files.
