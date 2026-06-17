# Implementation Plan: Epic 2 — Authentication

Branch: `feature/epic-2-authentication`
PR target: `epic/1-app-shell`
Date: 2026-06-17

---

## What Is Changing and Why

Adding browser-based OAuth authentication to the Neutrino Drive iOS app. Users must be able to
sign in via a web-based OAuth flow, have their tokens persisted to the iOS Keychain so the session
survives app restarts, and be routed to the main tab interface upon a valid session or to a
LoginView when no session exists.

No live auth server exists yet. The OAuth endpoint URL is extracted into a constant so it can be
swapped when the real server is available. The ASWebAuthenticationSession wiring is
production-correct even though it cannot complete end-to-end in the absence of a server.

---

## Layers Affected

| Layer | Status |
|---|---|
| iOS / SwiftUI — Services | New: KeychainService.swift, AuthService.swift |
| iOS / SwiftUI — Views | New: LoginView.swift; modified: NeutrinoDriveApp.swift, ContentView.swift |
| Backend (Rust) | Not touched in this epic |
| Tests | XCTest unit tests for KeychainService and AuthService |

---

## New Files

```
NeutrinoDrive/
  Services/
    KeychainService.swift     # SecItem CRUD wrapper
    AuthService.swift         # OAuth flow + Keychain persistence + @Published state
  Views/
    LoginView.swift           # "Sign In" screen shown when unauthenticated
  NeutrinoDriveApp.swift      # Modified: inject AuthService as @StateObject + route on auth state
  ContentView.swift           # No change needed (used as-is when authenticated)
NeutrinoDriveTests/
  KeychainServiceTests.swift
  AuthServiceTests.swift
```

---

## Architecture Decisions

### AuthService as ObservableObject
`AuthService` is an `ObservableObject` with `@Published var isAuthenticated: Bool`. The app root
observes it. When `isAuthenticated` is `false`, `LoginView` is presented fullscreen; when `true`,
`ContentView` (the tab shell) is shown. This keeps routing declarative and testable.

### KeychainService — thin SecItem wrapper
A struct with static `save`, `load`, and `delete` methods operating on `kSecClassGenericPassword`
items. Keys are string constants defined on `KeychainService` itself. No third-party deps.

### OAuth URL constants
All OAuth parameters live in an `AuthConfig` enum (or a nested struct on `AuthService`), so a
single-file change is enough to wire in the real endpoint later:
- `authorizationURL`: `https://auth.neutrinodrive.example.com/oauth/authorize`
- `callbackScheme`: `neutrinodrive`
- `callbackURL`: `neutrinodrive://oauth/callback`

### ASWebAuthenticationSession
Called on the main actor. The completion handler parses the callback URL for a code or token. In
the stub implementation it stores a placeholder token and sets `isAuthenticated = true`, simulating
a successful flow so the UI wiring can be verified in the simulator.

### Keychain keys
- `"nd.access_token"`
- `"nd.refresh_token"`

### App startup check
`AuthService.init()` reads Keychain. If both keys are present, sets `isAuthenticated = true`
immediately, skipping the login screen. If absent, `isAuthenticated` remains `false`.

### refreshTokenIfNeeded()
Async stub. Logs intent and returns. Full implementation deferred to a later epic when the real
token endpoint is known.

### logout()
Deletes both Keychain entries and sets `isAuthenticated = false`.

### Feature flag
Authentication is foundational and cannot be feature-flagged off (the app is unusable without it).
No flag is created. The auth server URL constant serves as the configuration swap point.

---

## Specialist Agents

| Agent | Task |
|---|---|
| `frontend-developer` | KeychainService, AuthService, LoginView, NeutrinoDriveApp updates |
| `ui-designer` | LoginView visual design — layout, typography, branding |
| `test-writer` | XCTest unit tests for KeychainService and AuthService |

The UI designer runs in parallel with the developer; the developer integrates the design output.

---

## Risks and Edge Cases

- **Simulator Keychain**: SecItem works in the Simulator but the keychain is shared per simulator
  device. Tests that write to Keychain must clean up after themselves.
- **ASWebAuthenticationSession requires a window scene**: Must be called with a valid
  `ASPresentationAnchor`. On iOS 16+ the window scene anchor is obtained from the active
  `UIWindowScene`. This requires a small UIKit bridge.
- **No real callback**: Without a server the OAuth session will time out or the user will cancel.
  The stub treats a cancel as a no-op (not an error), which is correct production behaviour.
- **project.yml / xcodegen**: New source groups (Services/, NeutrinoDriveTests/) must be added to
  `project.yml`. XcodeGen must be re-run to regenerate the `.xcodeproj`. If xcodegen is not
  available, the Swift files are placed correctly and the note is included in the PR.

---

## Acceptance Criteria

- [ ] Fresh launch with empty Keychain shows LoginView
- [ ] Tapping "Sign In" opens ASWebAuthenticationSession browser sheet
- [ ] After session (real or simulated stub), app transitions to ContentView tab shell
- [ ] Force-quitting and relaunching skips LoginView when tokens are in Keychain
- [ ] Tapping "Sign Out" in Settings clears Keychain and returns to LoginView
- [ ] `KeychainService` unit tests pass: save/load/delete round-trips
- [ ] `AuthService` unit tests pass: startup check, login sets isAuthenticated, logout clears it
- [ ] No third-party dependencies added
- [ ] iOS 16 deployment target unchanged
