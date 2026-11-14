# Neutrino Drive for iOS

The iPhone and iPad client for Neutrino Drive, end-to-end encrypted cloud storage. Files are encrypted on the device before upload and decrypted on the device after download, so the server only ever holds ciphertext.

## Features

- **File browser:** My Drive, Starred, Shared, Recents and Trash, with search, folders, rename, move and a sidebar layout on iPad.
- **Uploads and downloads:** large transfers run in a background `URLSession`, so they survive the app being suspended.
- **Viewers:** native preview for downloaded files, browsing inside zip archives, and an in-app web viewer for Neutrino Docs, Sheets, Slides, Diagrams and Drawings. Notes and documents open in their companion app when it is installed.
- **Offline:** keep files on the device. When the connection drops, the app says so, and it reloads folders when the connection returns.
- **Photo backup:** automatic, encrypted backup of the photo library, in the background.
- **Share extension:** send files, images, video, text and links to Drive from any app.
- **Sharing and history:** share with people or by link, and browse and restore earlier versions.
- **Encryption keys:** set up a key, or import one from a QR code, a key file or a Recovery Kit.
- **App Lock:** Face ID or Touch ID.
- **Universal Links:** `https://www.getneutrino.app/open/…` links open directly in the app. See [`deploy/README.md`](deploy/README.md).

Most features sit behind a compile-time switch in [`FeatureFlags.swift`](NeutrinoDrive/Config/FeatureFlags.swift). The Photos background-upload extension is built but currently off.

## Tech Stack

- Swift and SwiftUI, targeting iOS 16+ (the Photos background-upload extension requires iOS 27)
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), with `project.yml` as the source of truth for the Xcode project
- [swift-sodium](https://github.com/jedisct1/swift-sodium) for encryption
- [`NeutrinoShared`](https://github.com/wcherry/neutrino_shared_ios) for account identity, OAuth, the E2EE key lifecycle and the sign-in screens

## Getting Started

This repository must sit next to `neutrino_shared_ios`, because `project.yml` references that package by local path:

```
getneutrino.app/
├── neutrino_drive_ios_mobile/
└── neutrino_shared_ios/
```

Install XcodeGen, generate the project and open it:

```sh
brew install xcodegen
xcodegen generate
open NeutrinoDrive.xcodeproj
```

Change `project.yml` rather than the Xcode project, then run `xcodegen generate` again. To add or remove files, do the same, since the generated project picks them up from the source folders.

### Run

`scripts/run_simulator.sh` regenerates the project, builds it, and launches the app:

```sh
scripts/run_simulator.sh                     # iPhone 17 Pro simulator, Debug
scripts/run_simulator.sh --device "iPad Pro 13-inch (M4)"
scripts/run_simulator.sh --console           # stream the app's output
scripts/run_simulator.sh --physical          # the paired iPhone or iPad
```

Use a real device to test photo sync and background transfers, because the Simulator doesn't suspend the app or run a background `URLSession` the way iOS does.

### Test

```sh
xcodebuild test \
  -project NeutrinoDrive.xcodeproj \
  -scheme NeutrinoDrive \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

This repository has no CI, so run the tests locally. Manual checks for the current work are in [`VERIFY.md`](VERIFY.md).

### Deploy

`scripts/deploy_testflight.sh` bumps the build number, then archives and uploads to TestFlight. Copy `scripts/.env.example` to `scripts/.env` and add your App Store Connect credentials first.

```sh
scripts/deploy_testflight.sh                 # bump the build number by 1
scripts/deploy_testflight.sh 3 1.1.0         # build 3, version 1.1.0
```

## Architecture

The app is a four-tab SwiftUI shell (Files, Recents, Offline and Settings), and each tab has its own `NavigationStack`. The backend is the `/api/v1` API in [`wcherry/neutrino`](https://github.com/wcherry/neutrino).

| Path | Contents |
|------|----------|
| `NeutrinoDrive/Views/` | SwiftUI screens and sheets |
| `NeutrinoDrive/Services/` | API clients, transfers, encryption, search, offline storage and photo sync |
| `NeutrinoDrive/Models/` | Drive items, sections and offline records |
| `NeutrinoDrive/Config/` | Feature flags and the storage shared with the extensions |
| `NeutrinoDriveShare/` | Share extension |
| `NeutrinoDrivePhotoUpload/` | Photos background-upload extension |
| `NeutrinoDriveTests/` | Unit tests |
| `deploy/` | Reference copy of the Universal Links association file |
| `agent_docs/` | Plans and research notes |

The extensions run in separate processes. They share data with the app through the `group.com.neutrino.drive` App Group and a shared Keychain access group. Both extensions compile the same source files as the app for their upload path, listed under each target in `project.yml`, so that all three encrypt a file identically.
