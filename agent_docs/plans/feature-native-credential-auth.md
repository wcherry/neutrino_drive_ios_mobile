# Implementation Plan: Native Credential Sign-In + Refresh Token

## Branch
`feature/epic-2-authentication`

## What is changing and why

Replacing the browser-based OAuth flow (ASWebAuthenticationSession) with a native email/password form and a real refresh token implementation.

Reasons:
- Browser OAuth requires a running auth server and a URL scheme callback; neither exists yet.
- A native credential form gives a smoother UX and can show inline validation errors.
- `refreshTokenIfNeeded()` is currently a no-op stub; real token refresh is required for secure sessions.

## Layers affected

- **AuthService.swift** — remove ASWebAuthenticationSession/AuthenticationServices entirely; add `login(email:password:)`, `refreshTokenIfNeeded()`, `accessToken()`, `AuthError`, `AuthConfig`.
- **LoginView.swift** — replace single button with email field + password field + error label + loading state; call `authService.login(email:password:)` directly via @EnvironmentObject.
- **NeutrinoDriveApp.swift** — pass AuthService as EnvironmentObject to LoginView; remove `onSignIn` callback pattern.
- **AuthServiceTests.swift** — update/extend to cover login success, 401 throws, fresh-token no-op, logout clears all three keys.

## AuthConfig constants

```
loginURL    = "http://localhost:8080/api/auth/login"
refreshURL  = "http://localhost:8080/api/auth/refresh"
tokenExpiry = "nd.token_expiry"  (Keychain key)
```

## AuthError

```swift
enum AuthError: LocalizedError {
    case invalidCredentials
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
}
```

## login(email:password:) contract

- POST JSON `{"email": "...", "password": "..."}` to `AuthConfig.loginURL`
- 200 response: `{"access_token": "...", "refresh_token": "...", "expires_in": 3600}`
- 401 → throw `AuthError.invalidCredentials`
- other non-2xx → throw `AuthError.serverError(statusCode:)`
- network error → throw `AuthError.networkError(underlying:)`
- success: save access_token, refresh_token, expiry (ISO8601 Date+60s buffer) to Keychain; set isAuthenticated = true

## refreshTokenIfNeeded() contract

- Load expiry from Keychain; if absent or within 60s of now, proceed to refresh
- POST `{"refresh_token": "..."}` to `AuthConfig.refreshURL`
- 200 → update all three Keychain keys + new expiry, keep isAuthenticated = true
- 401 → call logout() (forces re-login)
- network error → do NOT log out (allow offline use)

## Feature flag

Not applicable — this replaces a stub with real behaviour. The change is gated by the fact that the server doesn't exist yet (localhost:8080), so a 401/network error is the expected simulator behaviour.

## Acceptance criteria

- [ ] LoginView shows email field, password field, Sign In button
- [ ] Tapping Sign In with any credentials hits localhost:8080 → receives network error or 401 → shows inline error label
- [ ] Successful 200 response stores tokens in Keychain and navigates to ContentView
- [ ] `refreshTokenIfNeeded()` is a no-op when token is fresh (expiry > now + 60s)
- [ ] `logout()` clears access_token, refresh_token, and nd.token_expiry from Keychain
- [ ] No import of AuthenticationServices anywhere in AuthService.swift
- [ ] All tests pass

## Risks / edge cases

- `@MainActor` isolation: URLSession calls must be wrapped in `Task` or `async` properly; `login()` is already `async throws` so this is fine.
- ISO8601 date encoding for token expiry must be consistent between write and read paths.
- LoginView needs to handle keyboard avoiding (ScrollView or `.ignoresSafeArea(.keyboard)`) so the form is visible when keyboard appears.
