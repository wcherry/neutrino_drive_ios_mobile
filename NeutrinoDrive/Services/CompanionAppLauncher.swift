import Foundation
import UIKit

// MARK: - CompanionAppLauncher

/// Hands a Drive file to the sibling Neutrino app that owns its format.
///
/// The whole point of asking iOS with `universalLinksOnly` is the *negative* answer: there is no
/// way to ask whether another app is installed (`canOpenURL` answers "yes" for every `https` URL,
/// because Safari can always take it). Opening with that option set means iOS either routes the
/// link to the installed app or reports failure — it never silently drops the user into Safari,
/// which is what lets Drive offer its own viewer as a fallback instead.
@MainActor
final class CompanionAppLauncher {

    // MARK: - Outcome

    enum Outcome: Equatable {
        /// The companion app was installed and has been brought to the front.
        case opened
        /// Nothing on this device claims the link. The caller should fall back.
        case appNotInstalled
        /// The destination could not be expressed as a link (empty file id).
        case invalidLink
    }

    // MARK: - Opener

    /// Injected so tests can drive both branches without a device: the real implementation is the
    /// one call in this file that cannot run in a unit test.
    typealias Opener = @MainActor (URL) async -> Bool

    private let opener: Opener

    /// `nonisolated` so a SwiftUI view can hold one as a stored property: view initialisers run
    /// outside the main actor's static isolation even though bodies are on it.
    nonisolated init(opener: Opener? = nil) {
        self.opener = opener ?? { url in
            await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
        }
    }

    // MARK: - Open

    /// Attempts to open `destination` in its companion app.
    @discardableResult
    func open(_ destination: NeutrinoAppLink.Destination) async -> Outcome {
        guard let url = NeutrinoAppLink.url(kind: destination.kind,
                                            fileID: destination.fileID,
                                            contentVersion: destination.contentVersion) else {
            return .invalidLink
        }
        return await opener(url) ? .opened : .appNotInstalled
    }

    /// Attempts to open the file in whichever app owns `mimeType`.
    /// Returns `.invalidLink` when no Neutrino app claims the type.
    @discardableResult
    func open(fileID: String, mimeType: String?) async -> Outcome {
        guard let kind = NeutrinoAppLink.kind(forMIME: mimeType) else { return .invalidLink }
        return await open(NeutrinoAppLink.Destination(kind: kind, fileID: fileID))
    }
}
