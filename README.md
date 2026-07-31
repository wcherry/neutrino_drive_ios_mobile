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
| Epic 8 | Offline Files | COMPLETE |
| Epic 9 | Search | COMPLETE |
| Epic 10 | Settings | COMPLETE |

## Getting Started

`project.yml` is the source of truth for the Xcode project; `NeutrinoDrive.xcodeproj` is generated from it and committed so the project opens without any setup. After changing `project.yml` — or after adding a file to a target that lists sources individually, such as either extension — regenerate it:

```sh
brew install xcodegen   # once
xcodegen generate
open NeutrinoDrive.xcodeproj
```

The workspace builds three bundles: the `NeutrinoDrive` app, the `NeutrinoDriveShare` share extension, and the `NeutrinoDriveFileProvider` File Provider extension.

## Deploying to TestFlight

```sh
cp scripts/.env.example scripts/.env   # then fill in App Store Connect credentials
scripts/deploy_testflight.sh           # bump the build number by 1 and ship
scripts/deploy_testflight.sh 7         # ship build 7
scripts/deploy_testflight.sh 7 1.1.0   # build 7, marketing version 1.1.0
```

The script bumps `CURRENT_PROJECT_VERSION` in `project.yml` (the source of truth — each `Info.plist` reads it through `$(CURRENT_PROJECT_VERSION)`), regenerates the project with XcodeGen, runs the unit tests, archives, exports an App Store `.ipa`, and uploads it with `xcrun altool`. `--skip-tests` and `--no-upload` are available for iterating. Commit the `project.yml` bump afterwards so the next build number starts from the right place.

Because the app embeds two extensions, all three bundles must carry the same version — App Store Connect rejects an upload whose extension versions disagree with the app's. The bump rewrites all three declarations at once, refuses to run if they had drifted apart beforehand, and re-checks every bundle's `CFBundleVersion` inside the exported `.ipa`.

Credentials come from `scripts/.env` (gitignored) — either an App Store Connect API key (`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH`) or an Apple ID with an app-specific password (`ASC_APPLE_ID` / `ASC_APP_PASSWORD`). See `scripts/.env.example`.

Signing is automatic and needs an *Apple Distribution* certificate for team `46KWJJ63FU`. Xcode 26 stores automatic-signing certificates in the data-protection keychain, where `security find-identity` cannot see them, so the script verifies the exported `.ipa`'s embedded provisioning profile and bundle versions instead of preflighting the keychain — a development-signed or stale-versioned build fails locally rather than being rejected by Apple ten minutes later.

The first upload additionally needs, in App Store Connect, an app record for `com.neutrino.drive`, and, in the developer portal, the App Group `group.com.neutrino.drive` and the keychain sharing group enabled on all three App IDs. Automatic signing creates the App IDs and profiles on demand; the app record itself has to be created by hand once.

## Architecture

The app is structured as a four-tab SwiftUI shell with tabs for Files, Recents, Offline, and Settings. Each tab is wrapped in a `NavigationStack` at the root `ContentView` level, keeping navigation state independent per tab. Future epics will layer in authentication, encryption key management, file browsing backed by the Neutrino Drive API, upload and download workflows, offline file caching, and full-text search across the user's stored files.
