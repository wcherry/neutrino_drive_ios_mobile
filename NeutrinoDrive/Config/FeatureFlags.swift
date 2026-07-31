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
}
