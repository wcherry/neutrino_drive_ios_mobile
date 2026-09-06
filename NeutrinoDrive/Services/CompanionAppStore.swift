import Foundation
import NeutrinoCore

// MARK: - CompanionAppStore

/// Where to send someone whose companion app turns out not to be installed.
///
/// App Store product ids are minted by App Store Connect when an app is first submitted, so they
/// cannot be derived from anything in this repository or guessed from the app's name — this table
/// is the one place they are written down.
///
/// An id that has not been filled in yet is *not* an error state. `url(for:)` returns nil, the
/// prompt leaves its install button out, and the user still gets "Open in Drive" — the behaviour
/// that shipped before any of this existed. That is the deliberate trade: a missing button is a
/// smaller failure than a button that opens a 404 on the App Store, and it means Sheets and Slides
/// can be routed to their apps today without waiting on a release date.
enum CompanionAppStore {

    // MARK: - Listings

    /// The numeric App Store item id for the app that owns `kind`, or nil while it has no listing.
    ///
    /// - TODO: Fill each of these in from App Store Connect as the app is published. Until an id
    ///   is set, that app's prompt shows only "Open in Drive".
    static func productID(for kind: NeutrinoAppLink.Kind) -> String? {
        switch kind {
        case .note:  return nil   // TODO: Neutrino Notes — shipping, id not recorded here yet
        case .doc:   return nil   // TODO: Neutrino Docs — shipping, id not recorded here yet
        case .sheet: return nil   // TODO: Neutrino Sheets — built, not yet released
        case .slide: return nil   // TODO: Neutrino Slides — no iOS target yet

        // Drive is the app doing the asking, and Diagrams and Drawings are web-only.
        case .file, .diagram, .drawing: return nil
        }
    }

    // MARK: - URL

    /// The App Store page for `kind`'s app, or nil when it has no listing yet.
    ///
    /// `itms-apps:` is used rather than `https://apps.apple.com/…` so the App Store opens directly.
    /// The https spelling also works, but it can bounce through Safari before redirecting, and a
    /// browser flashing up on the way to an install reads as the link having failed.
    static func url(for kind: NeutrinoAppLink.Kind) -> URL? {
        guard let productID = productID(for: kind) else { return nil }
        return URL(string: "itms-apps://apps.apple.com/app/id\(productID)")
    }

    /// True when there is somewhere to send the user. The prompt shows its install button on this.
    static func hasListing(for kind: NeutrinoAppLink.Kind) -> Bool {
        url(for: kind) != nil
    }
}
