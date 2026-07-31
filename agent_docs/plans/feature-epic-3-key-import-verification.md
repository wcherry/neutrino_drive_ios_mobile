# Manual Verification: Epic 3 — Key Import

## Prerequisites
- A valid key file exported from the Neutrino Drive web app (JSON with `public_key`, `private_key`, `key_version` fields, keys are Base64-encoded P-256)
- An iOS simulator or device running the app (signed in)
- For "Open In" testing: Safari or Files app on the device

---

## Steps to Verify

### Happy Path — File Picker

1. Build and run the app. Sign in.
2. Tap the **Settings** tab.
3. Under "Encryption Key", verify the row shows **"Import Key File"** (no keys stored yet).
4. Tap **Import Key File**. The key import sheet opens.
5. Tap **Import Key File** button inside the sheet. The system document picker opens.
6. Navigate to and select a valid `.json` key file.
7. Verify the sheet shows: "Keys imported successfully (v\<version\>)" in green.
8. The sheet dismisses automatically after ~1.5 seconds.
9. In Settings, the Encryption Key section now shows **"Encryption Key: Imported ✓"** and a **"Remove Keys"** button.
10. Kill and relaunch the app. Settings still shows "Encryption Key: Imported ✓" — confirming persistence.

### Happy Path — Open In

1. Ensure the app is installed (not just running in Xcode).
2. In Safari or the Files app, navigate to a valid `.json` key file.
3. Tap Share → Open In Neutrino Drive.
4. The app opens and displays a **"Key Import"** alert: "Encryption key v\<version\> imported successfully."
5. Tap OK.
6. Navigate to Settings → confirm "Encryption Key: Imported ✓" is shown.

### Remove Keys

1. With keys imported, go to Settings.
2. Tap **Remove Keys**.
3. A confirmation alert appears: "Remove Encryption Keys? This will delete your stored encryption keys..."
4. Tap **Remove**.
5. The section reverts to showing the **"Import Key File"** button.
6. Kill and relaunch — Settings still shows the import button (keys are gone).

### Error Cases

#### Invalid JSON
1. Create a file `bad.json` with content: `this is not json`.
2. Import via File Picker.
3. Verify an **"Import Failed"** alert appears: "The file is not valid JSON."

#### Missing Fields
1. Create `missing.json`: `{"public_key": "abc"}` (missing `private_key` and `key_version`).
2. Import via File Picker.
3. Verify alert: "The key file is missing required fields."

#### Mismatched Key Pair
1. Create `mismatch.json` where `public_key` and `private_key` are both valid Base64 P-256 keys but do NOT correspond to each other.
2. Import via File Picker.
3. Verify alert: "The public key and private key do not form a matching pair."

#### PEM Format
1. Create `pem.json` where `public_key` value starts with `-----BEGIN PUBLIC KEY-----`.
2. Import via File Picker.
3. Verify alert: "PEM-encoded keys are not supported. Please use raw or X9.63 Base64 encoding."

#### Cancel Import Sheet
1. Tap "Import Key File" in Settings.
2. Tap **Cancel** in the sheet toolbar.
3. Sheet dismisses; no keys are stored; Settings still shows the import button.

---

## Expected Results Summary

| Action | Expected |
|---|---|
| Import valid key file (picker) | Success message, keys stored, Settings shows "Imported ✓" |
| Import valid key file (Open In) | Alert with success message |
| Remove Keys | Confirmation dialog, then import button reappears |
| App relaunch with keys | Settings shows "Imported ✓" (Keychain persists) |
| App relaunch without keys | Settings shows "Import Key File" button |
| Invalid JSON | Alert "The file is not valid JSON." |
| Missing field | Alert "The key file is missing required fields." |
| Mismatched pair | Alert "The public key and private key do not form a matching pair." |
| PEM format | Alert "PEM-encoded keys are not supported..." |

---

## Rollback

No feature flag controls this feature in the current build. To disable key import on a device:
1. Delete and reinstall the app (clears Keychain).
2. Or ship a new build without the `KeyImportView` sheet trigger in `SettingsView`.

Keychain entries can also be cleared programmatically by calling `KeyImportService.removeKeys()` from a debug build.
