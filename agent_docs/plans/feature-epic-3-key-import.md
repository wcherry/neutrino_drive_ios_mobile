# Implementation Plan: Epic 3 — Key Import

## Branch
`feature/epic-3-key-import`

## What Is Changing and Why

Users export a JSON key file from the Neutrino Drive web app containing a P-256
key pair (`public_key`, `private_key`, `key_version`). The iOS app must import
and validate this key pair, store it securely in the Keychain, and expose it
later for file decryption.

Two import paths are required:
1. **File Picker** — user taps "Import Key File" in Settings, `UIDocumentPickerViewController` opens for `.json` files.
2. **Open In** — user downloads the key file in Safari/Mail and chooses "Open In Neutrino Drive"; the app receives the URL via `onOpenURL`.

## Layers Affected

| Layer | Change |
|---|---|
| New service | `KeyImportService.swift` — JSON parsing, key validation, Keychain storage |
| New view | `KeyImportView.swift` — SwiftUI sheet with document picker |
| Updated view | `SettingsView.swift` — key status row + Remove Keys button |
| Updated app entry | `NeutrinoDriveApp.swift` — `onOpenURL` handler |
| Updated plist | `Info.plist` — register `public.json` / `com.neutrino.drive.keyfile` document type |
| Updated project | `project.yml` — register new source files |
| New tests | `NeutrinoDriveTests/KeyImportServiceTests.swift` |

## New Files

```
NeutrinoDrive/Services/KeyImportService.swift
NeutrinoDrive/Views/KeyImportView.swift
NeutrinoDriveTests/KeyImportServiceTests.swift
```

## Key Design Decisions

### Key Format
The JSON contains Base64-encoded raw P-256 key bytes (or PEM). We attempt:
1. Standard Base64 → raw 65-byte uncompressed P-256 public key / 32-byte private key scalar
2. Base64URL variant (replace `-`→`+`, `_`→`/`)

CryptoKit `P256.Signing.PrivateKey(rawRepresentation:)` and
`P256.Signing.PublicKey(rawRepresentation:)` / `(x963Representation:)` are used
for import. Validation: sign a known test message with the private key, verify
with the public key. If that round-trip passes, the pair is coherent.

### Keychain Keys
```
nd.encryption.public_key
nd.encryption.private_key
nd.encryption.key_version
```

### Secure Enclave
`SecureEnclave.P256` requires the key to be *generated* in the enclave; it
cannot import an arbitrary private key scalar. Therefore we store the private key
in the regular Keychain (already encrypted by the OS) rather than the Secure
Enclave, which is the correct and standard approach for imported keys.

### Feature Flag
`feature.keyimport.enabled` — controlled via a compile-time `#if` placeholder
that defaults to ON for this epic (the feature flag infrastructure will be wired
to a remote config system in a later epic). The flag is documented here but the
implementation ships the feature ON since there is no remote flag service yet.

## Acceptance Criteria

- [ ] User can import a valid key file via the File Picker
- [ ] User can import a valid key file via Open In from another app
- [ ] Invalid JSON shows a clear error message
- [ ] Missing fields show a clear error message
- [ ] Mismatched key pair (public/private don't match) shows a clear error
- [ ] After import, Settings shows "Encryption Key: Imported" with key version
- [ ] Settings shows "Remove Keys" option when keys are present
- [ ] Remove Keys clears all three Keychain entries
- [ ] Keys persist across app restarts
- [ ] Unit tests cover all validation paths (happy path, missing fields, bad Base64, mismatched pair)
- [ ] Project compiles with `xcodegen generate` + `xcodebuild`

## Known Risks / Edge Cases

- Keys may arrive as Base64URL (web standard) vs standard Base64 — handle both
- PEM-wrapped keys (-----BEGIN...) are explicitly out of scope per the spec but we add a guard and a clear error
- The temp file from UIDocumentPicker must be copied before the security-scoped access expires; deleted after
- `onOpenURL` fires on the main actor; parsing should be done asynchronously
