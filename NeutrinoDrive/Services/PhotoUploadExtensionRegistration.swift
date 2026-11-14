import Foundation
import Photos
import os.log

// MARK: - PhotoUploadExtensionRegistration

/// Turns the Photos background-upload extension on and off with PhotoKit.
///
/// iOS launches the extension only while the app has it enabled, and enabling it needs full
/// photo library access. So it follows photo sync: on while photo sync is on with full access
/// and the feature flag allows it, off otherwise — including after the user narrows access to
/// a limited selection, when iOS would refuse the extension anyway.
enum PhotoUploadExtensionRegistration {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                       category: "PhotoUploadExtensionRegistration")

    /// Whether the extension should be enabled, separate from doing it so it can be tested.
    static func shouldEnable(featureEnabled: Bool, photoSyncEnabled: Bool,
                             authorization: PHAuthorizationStatus) -> Bool {
        featureEnabled && photoSyncEnabled && authorization == .authorized
    }

    /// Brings PhotoKit's registration in line with photo sync's settings. Cheap when nothing
    /// changed, so it is called on every `start()`.
    ///
    /// - Parameter wifiOnly: becomes `preventsExpensiveNetworkAccess`, so iOS does not launch
    ///   the extension to send photos over cellular when photo sync is Wi-Fi only.
    static func update(photoSyncEnabled: Bool, authorization: PHAuthorizationStatus, wifiOnly: Bool) {
        guard #available(iOS 27.0, *) else { return }
        let wanted = shouldEnable(
            featureEnabled: FeatureFlags.photoAutoSync && FeatureFlags.photoUploadExtension,
            photoSyncEnabled: photoSyncEnabled,
            authorization: authorization
        )
        // Asking PhotoKit about the extension needs some photo access; without it there is
        // nothing to enable, and nothing iOS would launch.
        guard authorization == .authorized || authorization == .limited else { return }
        let library = PHPhotoLibrary.shared()
        do {
            if wanted {
                let options = PHAssetResourceUploadJobOptions()
                options.preventsExpensiveNetworkAccess = wifiOnly
                if !library.uploadJobExtensionEnabled {
                    try library.enableUploadJobExtension(with: options)
                    logger.info("enabled the Photos upload extension")
                } else if library.uploadJobExtensionOptions?.preventsExpensiveNetworkAccess != wifiOnly {
                    try library.setUploadJobExtensionOptions(options)
                }
            } else if library.uploadJobExtensionEnabled {
                try library.disableUploadJobExtension()
                logger.info("disabled the Photos upload extension")
            }
        } catch {
            logger.error("could not update the Photos upload extension: \(error, privacy: .public)")
        }
    }
}
