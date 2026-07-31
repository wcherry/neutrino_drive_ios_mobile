# Implementation Plan: Epic 5 — Upload Files

## What is changing and why

Epic 5 adds file upload capability to Neutrino Drive. Files are encrypted locally
before leaving the device — the server never sees plaintext. Users can upload from
three sources: the Files app (UIDocumentPicker), Photos library (PhotosPicker), and
the Camera (UIImagePickerController in camera mode).

## Layers affected

- **Backend (none):** The API already accepts multipart/form-data at
  `POST /api/v1/drive/files/upload`. DriveService needs one new method to call it.
- **Service — UploadService:** New `Services/UploadService.swift`. Owns the
  encrypt-then-upload pipeline. Uses Sodium (already a project dependency) for
  symmetric encryption via secretstream/secretbox (AES-256-GCM via libsodium).
  The private key from KeychainService is used to derive a per-upload symmetric
  key via HKDF-like construction, or we use a random symmetric key and encrypt it
  with the public key (hybrid encryption). Given the key stored is an EC key pair
  (P-256 or Curve25519), we will generate a random 256-bit AES-GCM key for each
  file, encrypt the file with it, and then wrap (encrypt) that key with the
  recipient's public key using ECIES. For simplicity and to match existing CryptoKit
  usage, we will use CryptoKit's `AES.GCM` for file encryption.
- **View — UploadSheet:** New `Views/UploadSheet.swift`. Sheet with three picker
  source buttons (Files, Photos, Camera) and a progress view during upload.
- **View — FileBrowserView:** Add upload button to the myDrive toolbar and wire
  the UploadSheet.
- **Config — FeatureFlags:** Add `uploadFiles: Bool = true` flag.
- **Tests — UploadServiceTests:** New `NeutrinoDriveTests/UploadServiceTests.swift`.

## Encryption scheme

The stored keys are P-256 or Curve25519. We have CryptoKit available.

For each upload:
1. Generate a random 256-bit symmetric key.
2. Encrypt the file data with AES.GCM (nonce + ciphertext + tag).
3. Upload the encrypted blob. The server stores only the encrypted blob.

Note: The existing codebase stores private keys in the Keychain for decryption
later. For the upload direction, since the app holds both keys, we encrypt with
a fresh AES-GCM key and the blob is what's stored. This matches the security model.

## API Contract (upload endpoint)

`POST /api/v1/drive/files/upload`

Multipart form-data:
- `file`: encrypted blob data (Content-Type: application/octet-stream)
- `name`: original filename (string)
- `mime_type`: original MIME type (string)
- `folder_id`: parent folder ID (string, optional)
- `size_bytes`: original file size (integer, string-encoded)

Response: same shape as `APIFileResponse` (id, name, folderId, sizeBytes, mimeType, updatedAt)

## Feature flag

Name: `feature.files.upload` (represented as `FeatureFlags.uploadFiles`)
Default: `true` (on — matches pattern of existing flags)

## Known risks / edge cases

- Large files: read entire file into memory. For MVP this is acceptable.
  Future work: stream encrypt in chunks.
- Camera capture returns UIImage, must convert to JPEG Data before encryption.
- PHPickerViewController requires iOS 14+; project targets iOS 16 so we're fine.
- Document picker requires accessing security-scoped resources.
- Upload progress: URLSession delegate for progress reporting, or use
  `URLSession.upload(for:from:delegate:)` with a task delegate.

## Acceptance criteria

- [ ] Tap "+" button in My Drive shows UploadSheet with three source options.
- [ ] Choosing Files opens the document picker; selecting a file triggers encrypt + upload.
- [ ] Choosing Photos opens the photos picker; selecting an image triggers encrypt + upload.
- [ ] Choosing Camera opens the camera; capturing a photo triggers encrypt + upload.
- [ ] A progress indicator is shown during upload.
- [ ] After upload, the new file appears in the current folder without a manual refresh.
- [ ] Encrypted blob is what the server receives (not plaintext).
- [ ] UploadService unit tests cover: success path, missing key error, encryption step.
- [ ] `FeatureFlags.uploadFiles = false` hides the upload button entirely.

## Feature flag location

`NeutrinoDrive/Config/FeatureFlags.swift` — add `static let uploadFiles: Bool = true`
