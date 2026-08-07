import Foundation
import os.log

// MARK: - DeepLinkRouter

/// Holds the file an inbound Universal Link asked for until the app is in a state to show it.
///
/// A link can arrive at any moment — including a cold launch straight into the login screen, or
/// while the biometric lock overlay is up. Rather than have the open path deal with those states,
/// the router just remembers the destination; the view layer consumes it once the user is signed
/// in. That is also why `pending` is cleared only by `consume()` and not by presentation: a link
/// that arrives before sign-in has to survive the whole login round trip.
@MainActor
final class DeepLinkRouter: ObservableObject {

    // MARK: - State

    /// The destination waiting to be shown, if any.
    @Published private(set) var pending: NeutrinoAppLink.Destination?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                category: "DeepLinkRouter")

    // MARK: - Init

    init(pending: NeutrinoAppLink.Destination? = nil) {
        self.pending = pending
    }

    // MARK: - Inbound

    /// Records `url` if it is a Neutrino app link this app can serve.
    ///
    /// Returns false for anything else, which is the signal to the caller that the URL is still
    /// unclaimed — Drive's `onOpenURL` also carries the key-file "Open In" flow.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let destination = NeutrinoAppLink.destination(from: url) else { return false }
        guard Self.canOpen(destination.kind) else {
            logger.debug("ignoring app link for kind=\(destination.kind.rawValue, privacy: .public)")
            return false
        }
        logger.debug("accepted app link kind=\(destination.kind.rawValue, privacy: .public) file=\(destination.fileID, privacy: .public)")
        pending = destination
        return true
    }

    /// Returns the pending destination and clears it, so a presentation that has begun is not
    /// begun a second time when the view tree re-evaluates.
    func consume() -> NeutrinoAppLink.Destination? {
        defer { pending = nil }
        return pending
    }

    func clear() {
        pending = nil
    }

    // MARK: - Claims

    /// Drive accepts every kind, not just `.file`.
    ///
    /// The `apple-app-site-association` document only routes `/open/file/*` here, so in practice
    /// the other kinds arrive by other means — a link pasted into Drive, or a Notes link on a
    /// device where Notes has since been deleted. Drive can open any of them (they are all Drive
    /// files), and refusing would strand the user on a link that has nowhere else to go.
    private static func canOpen(_ kind: NeutrinoAppLink.Kind) -> Bool { true }
}
