enum FeatureFlags {
    /// Set to true to enable the QR code key import flow.
    static let qrKeyScan: Bool = true

    /// Set to true to enable the Epic 4 File Browser feature.
    /// When false, the Files tab shows the legacy placeholder.
    static let fileBrowser: Bool = true

    /// Set to true to enable the Epic 5 Upload Files feature.
    /// When false, the upload "+" button is hidden in My Drive.
    static let uploadFiles: Bool = true

    /// Set to true to enable the Epic 6 Download Files feature.
    /// When false, tapping a file does nothing.
    static let downloadFiles: Bool = true

    /// Set to true to enable the Epic 7 Neutrino-native file viewer.
    /// When true, tapping a Doc/Sheet/Slide/Diagram/Drawing opens the
    /// in-app web viewer instead of triggering a download.
    static let viewNeutrinoFiles: Bool = true

    /// Set to true to enable the Epic 8 Offline Files feature.
    /// When false, the "Make Available Offline" context menu action is hidden in My Drive
    /// (the Offline tab still shows any previously-cached files).
    static let offlineFiles: Bool = true

    /// Set to true to enable the Epic 9 Search feature.
    /// When false, the search field is hidden from the My Drive list.
    static let search: Bool = true

    /// Set to true to enable automatic background sync of new photos to Drive.
    /// When false, the Photo Sync section is hidden in Settings and no PhotoKit
    /// observer or background task is registered.
    static let photoAutoSync: Bool = true

    /// Set to true to enable the Phase 2 Face ID / Touch ID lock.
    /// When false, the Security section is hidden in Settings, no lock overlay is
    /// ever presented, and `BiometricAuthService` reports every gate as passed —
    /// so a disabled feature never prompts and never blocks.
    static let biometricLock: Bool = true

    /// Set to true to enable the Phase 2 share extension upload path.
    /// When false, the extension shows an "unavailable" message instead of
    /// uploading. (Removing the extension from the Share sheet entirely requires
    /// uninstalling the app — an extension's presence is a bundle property, not a
    /// runtime one.)
    static let shareExtension: Bool = true

    /// Set to true to route large upload/download transfers through a
    /// `.background` URLSession, so they survive app suspension.
    /// When false, transfers use a standard foreground session — the pre-Phase-2
    /// behaviour. This is a real kill switch: it swaps only the session
    /// configuration, so a regression in the background path can be turned off
    /// without reverting the refactor.
    static let backgroundTransfers: Bool = true

    /// Set to true to enable the Phase 5 sharing feature.
    /// When false, the "Share" context-menu action is hidden and the app issues no
    /// permission, user-lookup, or key-share request at all — so a disabled feature can
    /// never re-wrap a DEK to the wrong recipient.
    static let sharing: Bool = true

    /// Set to true to enable the Phase 5 version history feature.
    /// When false, the "Version History" context-menu action is hidden. Historical versions
    /// are decrypted through the same `DownloadService` path as current files, so this flag
    /// gates only the listing and restore UI, not any separate crypto.
    static let versionHistory: Bool = true

    /// Set to true to enable the Phase 5 favorites feature.
    /// When false, the star action is hidden from context menus and the "Starred" section is
    /// dropped from `DriveSection.visibleCases`, so neither the iPhone picker nor the iPad
    /// sidebar offers it.
    static let favorites: Bool = true

    /// Set to true to register the Phase 3 File Provider domain, which is what makes
    /// "Neutrino Drive" appear in the Files app and in every document picker.
    ///
    /// When false no domain is ever registered, so the location does not appear and the
    /// extension is never invoked. The extension is still *present* in the bundle — an
    /// extension's presence is a bundle property, not a runtime one, the same caveat already
    /// recorded for `shareExtension` — but with no domain there is nothing to invoke it.
    static let filesAppIntegration: Bool = true

    /// Set to true to handle documents opened **in place** by other apps.
    ///
    /// Pairs with `LSSupportsOpeningDocumentsInPlace` in `project.yml`, which is the half that
    /// actually decides what iOS hands over; this flag gates the app's handling. When false the
    /// app still refuses to delete a document it did not copy — that safety is in
    /// `IncomingDocument`, not in this flag, because a flag must never be the only thing
    /// standing between a user and a deleted file.
    static let openInPlace: Bool = true

    /// Set to true to enable Phase 3 CoreSpotlight indexing of file and folder **metadata**.
    ///
    /// Note the two-level gate: this flag being true does **not** enable indexing. The
    /// user-facing setting (`SpotlightIndexService.isEnabled`) is independently `false` until
    /// somebody turns it on, because CoreSpotlight's index is not end-to-end encrypted and
    /// filenames are frequently the most sensitive thing about a file. See the type
    /// documentation on `SpotlightIndexService` for the full reasoning.
    ///
    /// When false: no index write, no de-index, and the Settings section is hidden.
    static let spotlightSearch: Bool = true

    /// Set to true to stream large video and audio instead of downloading them in full.
    ///
    /// **This flag governs a security trade, so it is worth understanding before flipping.**
    /// Streaming serves *unauthenticated* plaintext: one Poly1305 MAC covers the whole file, so
    /// verifying any byte needs every byte, which a seeking player never reads. See
    /// `EncryptedMediaStream` for the full reasoning and for the scope rule that confines the
    /// exposure to transient playback — anything written to disk, exported, or cached offline
    /// always uses the authenticated `SecretStreamCrypto.decrypt(fileAt:to:key:)`.
    ///
    /// When false, media opens through the existing full-download path with the MAC verified
    /// before a single frame is shown. That is the correct setting for a deployment unwilling
    /// to accept the trade; it costs start-up latency and a full copy on disk, not correctness.
    ///
    /// Note this flag does **not** gate the constant-memory streaming *decrypt*, which is
    /// unconditional and purely a win — it is what removed the File Provider's 64 MB ceiling.
    static let largeFileStreaming: Bool = true

    /// Set to true to automatically cache recently- and frequently-used files for offline use.
    ///
    /// When false, no access is recorded at all (not merely unused — `FileAccessTracker`
    /// records nothing), no automatic download runs, and the Settings section is hidden.
    /// Manual "Make Available Offline" is untouched: a user's explicit pin is not this
    /// feature's business.
    static let smartOfflineSync: Bool = true

    /// Set to true to allow multiple document windows on iPad (and Stage Manager / external
    /// displays, which are the same scene machinery).
    ///
    /// When false the secondary `WindowGroup` is not declared, so `openWindow` has nothing to
    /// open and the app behaves exactly as the single-window build did.
    static let multiWindow: Bool = true

    /// Set to true to enable drag and drop between Neutrino Drive and other apps.
    ///
    /// When false no `.draggable`/`.dropDestination` modifier is attached anywhere, so no drag
    /// can start and no drop is accepted. Worth a flag of its own because dragging a file *out*
    /// hands another app decrypted bytes — intended, and the entire point, but the one gesture
    /// that crosses the encryption boundary.
    static let dragAndDrop: Bool = true
}
