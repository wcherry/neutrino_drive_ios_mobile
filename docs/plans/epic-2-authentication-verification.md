# Manual Verification: Epic 2 — Authentication

## Prerequisites

- Xcode 16 installed
- iOS 16+ Simulator (e.g. iPhone 16, iOS 18)
- NeutrinoDrive.xcodeproj opened in Xcode (run `xcodegen generate` if you cloned fresh)
- No prior test tokens in the simulator Keychain (reset simulator or use a fresh one)

## Scheme

Select the `NeutrinoDrive` scheme and any iOS 16+ simulator.

---

## Steps to Verify

### 1. Fresh Launch — LoginView Shown

1. Reset the simulator content and settings: Device menu → Erase All Content and Settings
2. Build and run (Cmd+R)
3. **Expected:** LoginView appears immediately — no tabs visible
4. **Expected:** App icon tile (indigo/blue "externaldrive.fill.badge.wifi") at top
5. **Expected:** "Neutrino Drive" title and "Secure encrypted file storage" subtitle
6. **Expected:** Three trust indicators (End-to-end encrypted, Zero-knowledge cloud storage, Only you hold your keys)
7. **Expected:** "Sign In" button at the bottom spanning most of the screen width

### 2. Sign In Button — Browser Sheet Opens

1. Tap "Sign In"
2. **Expected:** Button is replaced by a ProgressView (loading spinner) immediately
3. **Expected:** ASWebAuthenticationSession presents a Safari-style sheet (browser sheet)
4. **Expected:** The sheet attempts to load `https://auth.neutrinodrive.example.com/oauth/authorize` (this will fail to connect — that is expected)

### 3. Cancel Sign In — App Stays on LoginView

1. Dismiss the browser sheet by tapping "Cancel" or swiping down
2. **Expected:** Returned to LoginView with the "Sign In" button visible again (isLoading resets)
3. **Expected:** isAuthenticated is still false — no transition to tab view

   Note: The current LoginView sets `isLoading = true` when the button is tapped and does not
   reset it on cancellation because `onSignIn` is fire-and-forget. If the spinner persists after
   cancel, this is a known UX limitation to address in a future ticket. The auth state (not
   authenticated) is correct.

### 4. Simulated Successful Login

   Because there is no live auth server, test the stub path:

   **Option A — Intercept via URL scheme (advanced):**
   1. In Safari on the simulator, navigate to `neutrinodrive://oauth/callback?access_token=test123`
   2. This triggers the callback URL scheme and completes the session

   **Option B — Temporarily set stub token directly (developer test):**
   1. In `AuthService.login()`, temporarily add `continuation.resume(returning: URL(string: "neutrinodrive://oauth/callback?access_token=test123")!)` before the session starts
   2. Run, tap Sign In — the stub completes immediately

   **Expected after either option:**
   - LoginView disappears
   - ContentView tab bar appears with Files / Recents / Offline / Settings tabs
   - App is in authenticated state

### 5. Session Persists After Restart

1. After step 4, force-quit the app (swipe up from app switcher)
2. Relaunch from the Home Screen or Xcode
3. **Expected:** App launches directly to ContentView tab bar — LoginView does NOT appear
4. **Expected:** Tokens persisted in Keychain survived the restart

### 6. Sign Out

1. Tap the Settings tab
2. **Expected:** "Sign Out" row visible with a red destructive style
3. Tap "Sign Out"
4. **Expected:** App immediately returns to LoginView
5. **Expected:** No tab bar visible
6. Force-quit and relaunch
7. **Expected:** LoginView shown again (Keychain was cleared)

### 7. Sign Out When Already Logged Out (Robustness)

1. From LoginView, use Xcode debugger or the Settings workaround to call `authService.logout()` twice
2. **Expected:** No crash, no unexpected behaviour

---

## Feature Flag

This epic has no feature flag — authentication is foundational and cannot be disabled. The OAuth
endpoint URL constant (`AuthConfig.authorizationURL` in `AuthService.swift`) is the configuration
swap point. To connect to a real server, update that constant plus `callbackScheme` and
`callbackURL`.

---

## Expected Results Summary

| Scenario | Expected |
|---|---|
| Cold start, no Keychain tokens | LoginView shown |
| Cold start, tokens present | ContentView (tabs) shown immediately |
| Tap Sign In | Browser sheet opens |
| Cancel browser sheet | LoginView shown, not authenticated |
| Successful callback URL received | ContentView shown |
| App restart after login | ContentView shown (tokens restored) |
| Tap Sign Out | LoginView shown |
| Restart after sign out | LoginView shown |

---

## Rollback

Authentication cannot be feature-flagged off. To revert:
- Check out `epic/1-app-shell` — the pre-auth shell is intact there.
- The `feature/epic-2-authentication` branch can be abandoned without affecting `epic/1-app-shell`.
