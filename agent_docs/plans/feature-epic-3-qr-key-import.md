# Plan: Epic 3 — QR Code Key Import

Branch: `feature/epic-3-qr-key-import`
Base: `feature/epic-3-key-import` (merged into this branch)

## What is changing and why

The Neutrino Drive web app can encode an encrypted keypair into a QR code. The
mobile app needs a camera-scan flow so users can import keys without needing to
transfer a JSON file. This is an additive change — the existing JSON file picker
in `KeyImportView` is kept unchanged and a second "Scan QR Code" button is added
alongside it.

## Protocol

QR string format:
```json
{ "v": 1, "alg": "argon2id+xchacha20", "payload": "<base64>" }
```

`payload` is a base64-encoded UTF-8 JSON string:
```json
{ "salt": "<base64>", "nonce": "<base64>", "ct": "<base64>" }
```

- KDF: Argon2id, 65536 KB memory, 2 ops, parallelism 1, 32-byte output
- Cipher: XChaCha20-Poly1305 (libsodium secretBox — tag prepended to ciphertext)
- Plaintext: `{ "public_key": "...", "private_key": "...", "key_version": "1" }`

## Layers affected

| Layer | Change |
|---|---|
| Backend | None |
| Services (Swift) | New `KeyQRDecryptService.swift` |
| Views (SwiftUI) | New `QRScannerView.swift`, `KeyQRImportView.swift`; modified `KeyImportView.swift` |
| Design | Integrated into existing design language (no new design tokens needed) |
| Tests | New `KeyQRDecryptServiceTests.swift` |
| Config | `project.yml` — add swift-sodium package + camera usage description |

## Specialist agents needed

- `frontend-developer` (SwiftUI/iOS context): Implement service, views, and project config
- `test-writer`: Write `KeyQRDecryptServiceTests.swift`

## Feature flag

Flag name: `feature.keyimport.qr-scan`
Implementation: A compile-time constant in `NeutrinoDrive/Config/FeatureFlags.swift`
Default: OFF in production; enabled during development and testing

```swift
enum FeatureFlags {
    static let qrKeyScan: Bool = true  // set false to disable QR entry point
}
```

The "Scan QR Code" button in `KeyImportView` and the `KeyQRImportView` sheet are
gated behind `FeatureFlags.qrKeyScan`.

## New files

1. `NeutrinoDrive/Config/FeatureFlags.swift` — feature flag definition
2. `NeutrinoDrive/Services/KeyQRDecryptService.swift` — QR parse + decrypt pipeline
3. `NeutrinoDrive/Views/QRScannerView.swift` — VisionKit DataScanner wrapper
4. `NeutrinoDrive/Views/KeyQRImportView.swift` — scan-then-PIN-then-import sheet
5. `NeutrinoDriveTests/KeyQRDecryptServiceTests.swift` — unit tests

## Modified files

6. `NeutrinoDrive/Views/KeyImportView.swift` — add second "Scan QR Code" button
7. `project.yml` — add swift-sodium package + `NSCameraUsageDescription`

## Known risks and edge cases

- `DataScannerViewController` requires iOS 16+ AND a physical device capable of
  the Vision scanner — `DataScannerViewController.isSupported` must be checked.
- swift-sodium returns `[UInt8]` (Bytes); must convert to/from `Data`.
- The secretBox `open` call expects `(authenticatedCipherText: nonce:)` — nonce
  is separate from the ciphertext (the 16-byte Poly1305 tag is part of `ct`).
- Argon2id is memory-intensive; must be dispatched off the main thread.

## Acceptance criteria

- Tapping "Scan QR Code" opens the camera scanner sheet.
- A valid QR is scanned, PIN entry is shown.
- Correct PIN → keys stored → success state → auto-dismiss after 1.5 s.
- Wrong PIN → `decryptionFailure` error shown to user.
- Device not supported → graceful message.
- Feature flag OFF → "Scan QR Code" button not visible; JSON import unaffected.
- All unit tests pass (`KeyQRDecryptServiceTests`).

## Dependencies

- swift-sodium 0.9.1+: https://github.com/jedisct1/swift-sodium
  Added to `project.yml` packages section and as a target dependency.
