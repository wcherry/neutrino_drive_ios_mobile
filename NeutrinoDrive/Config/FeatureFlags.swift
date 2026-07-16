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
}
