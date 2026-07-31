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
}
