# Implementation Plan: Epic 1 — Mobile Application Shell

Branch: `epic/1-app-shell`
Date: 2026-06-17

---

## What Is Changing and Why

Creating the initial SwiftUI iOS application shell for Neutrino Drive — a secure mobile file browser
for an encrypted cloud drive service. This is Epic 1 of the MVP. No backend or API integration
exists yet; this epic delivers only the navigational skeleton so the app can be launched and the
four primary tabs can be reached.

---

## Layers Affected

| Layer | Status |
|---|---|
| iOS / SwiftUI | New — all source files created from scratch |
| Backend (Rust) | Not touched in this epic |
| Frontend (web) | Not touched in this epic |
| Tests | No XCTest targets yet; manual verification only for this shell epic |

---

## Files to Create

```
NeutrinoDrive/
  NeutrinoDriveApp.swift       # @main App entry point, SwiftUI App lifecycle
  ContentView.swift            # Root TabView with 4 tabs, each wrapping a NavigationStack
  Views/
    FilesView.swift            # Files tab — placeholder NavigationStack + title
    RecentsView.swift          # Recents tab — placeholder
    OfflineView.swift          # Offline tab — placeholder
    SettingsView.swift         # Settings tab — placeholder
README.md                      # Repo-root README
.gitignore                     # Swift/Xcode .gitignore
docs/plans/epic-1-app-shell.md # This file
```

---

## Architecture Decisions

- **SwiftUI App lifecycle** (`@main`, `WindowGroup`) — no UIKit AppDelegate needed for the shell.
- **TabView at root** — `ContentView` owns the `TabView`. Each tab item wraps its own
  `NavigationStack` so tab navigation stacks are independent.
- **iOS 16 minimum** — `NavigationStack` requires iOS 16+; avoids the deprecated
  `NavigationView`. Safe to use `NavigationStack` without back-porting.
- **SF Symbols** — `folder`, `clock`, `arrow.down.circle`, `gear` for the four tabs.
- **No feature flags needed** — this is a pure structural shell with no logic to gate.

---

## Specialist Agents

| Agent | Task |
|---|---|
| `frontend-developer` | Write all Swift/SwiftUI source files |
| `ui-designer` | Not needed — shell uses standard SF Symbols and system tab styling |
| `rust-developer` | Not needed — no backend in this epic |
| `test-writer` | Not needed — no testable logic yet; structural shell only |

---

## Risks and Edge Cases

- No `.xcodeproj` is generated — source files only. Developer must create project in Xcode and
  add these files. This is noted in the README.
- Bundle identifier `com.neutrino.drive` is set as a comment/note only; the actual value is
  configured inside Xcode project settings, not in source files.

---

## Acceptance Criteria

- [ ] App compiles and launches in Xcode simulator (iOS 16+)
- [ ] Four tabs are visible: Files, Recents, Offline, Settings
- [ ] Each tab shows its name as a navigation title
- [ ] Each tab uses the correct SF Symbol icon
- [ ] `.gitignore` excludes standard Xcode build artefacts
- [ ] README explains the project and how to open in Xcode
- [ ] All files committed to `epic/1-app-shell` branch
