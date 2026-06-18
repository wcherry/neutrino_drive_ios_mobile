enum FeatureFlags {
    /// Set to true to enable the QR code key import flow.
    static let qrKeyScan: Bool = true

    /// Set to true to enable the Epic 4 File Browser feature.
    /// When false, the Files tab shows the legacy placeholder.
    static let fileBrowser: Bool = true

    /// Set to true to enable the Epic 5 Upload Files feature.
    /// When false, the upload "+" button is hidden in My Drive.
    static let uploadFiles: Bool = true
}
