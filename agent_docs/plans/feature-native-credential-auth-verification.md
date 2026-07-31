# Manual Verification: Native Credential Sign-In

## Prerequisites

- Xcode 15+ with iOS 16 simulator available
- No `localhost:8080` server running (expected — the app will show an error label)
- Clean simulator state (or delete the app to clear Keychain)

## Steps to Verify

### Happy Path (requires running server)

If a compatible server is running at `http://localhost:8080/api/auth/login`:

1. Launch the app in the simulator.
2. Confirm the login screen shows: app icon, "Neutrino Drive" title, tagline, three trust rows, email field, password field, and Sign In button.
3. Enter a valid email and password.
4. Tap Sign In.
5. Confirm a loading spinner replaces the button during the request.
6. Confirm the app navigates to ContentView on success.
7. Force-quit and relaunch — confirm the app goes directly to ContentView (Keychain restored session).

### Error State — Invalid Credentials (401)

1. Launch the app.
2. Enter any email and a wrong password.
3. Tap Sign In.
4. Confirm a red inline error label appears: "Invalid email or password."
5. Confirm the form fields are re-enabled and the button is visible again.

### Error State — Server Unreachable (no localhost:8080)

1. Launch the app with no server running.
2. Enter any email and password.
3. Tap Sign In.
4. Confirm a red inline error label appears: "A network error occurred. Please check your connection."
5. Confirm the loading spinner disappears and the form is interactive again.

### Button Disabled State

1. Launch the app.
2. Confirm the Sign In button is dimmed (opacity ~0.55) when email or password is empty.
3. Type in the email field only — button stays dimmed.
4. Type in the password field — button becomes fully opaque.

### Keyboard Avoidance

1. Tap the email field — keyboard appears.
2. Confirm the form fields remain visible and are not hidden behind the keyboard.
3. Tap the password field — confirm it is also visible.

### Logout Clears All Keychain Keys

1. After a successful login, go to Settings in the app.
2. Tap Sign Out.
3. Confirm the app returns to the login screen.
4. Force-quit and relaunch — confirm the login screen is shown (not ContentView).

### Refresh Token — Fresh Token No-Op

1. After login, background and foreground the app.
2. Confirm no unnecessary network traffic is generated when the token is fresh (use Charles Proxy or Instruments).

### Refresh Token — Expired Token

1. Manually update the `nd.token_expiry` Keychain key to a past timestamp (requires a Keychain editor tool or test helper).
2. Background and foreground the app.
3. Confirm a refresh request is sent to `http://localhost:8080/api/auth/refresh`.

## Expected Results

- Email field: keyboard type is email, no autocapitalization, autocorrect off.
- Password field: text is masked.
- Error label: red, includes warning icon, appears with a fade-in animation.
- Sign In button: gradient matches existing app branding (indigo → blue).
- No browser sheet opens at any point.
- No `AuthenticationServices` framework is used.

## Rollback

There is no feature flag for this change — it is a direct replacement of the stub OAuth flow. To roll back, revert to the previous commit on the `feature/epic-2-authentication` branch.
