import Foundation

/// The two Live Photo rules every upload path has to agree on (#42, #44): whether the motion is
/// kept, and what the clip is called.
///
/// Its own file, Foundation only, because three targets need it: the app, the Photos extension
/// (through `PhotoSyncCore.swift` and `PhotoAssetExporter.swift`), and the share extension,
/// which compiles neither of those and shouldn't have to pull in the sync queue and PhotoKit
/// just to read one setting and name one file.
enum LivePhotoMotionRules {

    /// The **Keep Live Photo Motion** setting, in the App Group defaults so the extensions read
    /// what Settings wrote. Photo sync's key, because that is where the setting lives.
    static let settingKey = "photoSync.keepLivePhotoMotion"

    /// The setting as stored. On by default: a Live Photo without its motion isn't what the user
    /// took.
    static func keepsMotion(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? true
    }

    /// The clip is named after its still, never after itself: the shared stem is how a still and
    /// its clip are paired when nothing else links them (Apple's own export, Google Takeout and
    /// the web's `pairMotionPhotos` all rely on it). `IMG_1234.HEIC` + `IMG_1234.MOV` →
    /// `IMG_1234.MOV`; a clip named differently (an edited `FullSizeRender.mov`, or whatever a
    /// Live Photo bundle calls it) still gets the still's stem.
    static func pairedVideoFileName(stillName: String, videoName: String) -> String {
        let stem = (stillName as NSString).deletingPathExtension
        let ext = (videoName as NSString).pathExtension
        return "\(stem).\(ext.isEmpty ? "MOV" : ext)"
    }
}
