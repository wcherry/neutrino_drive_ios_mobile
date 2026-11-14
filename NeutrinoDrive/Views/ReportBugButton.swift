import SwiftUI
import UIKit
import NeutrinoCore

// MARK: - BugReport

/// The GitHub issue form behind "Report a Bug", and the device facts it opens prefilled with.
///
/// Reports go to this app's own repository rather than the central `wcherry/neutrino` tracker. A
/// report filed from inside Neutrino Drive already knows which app it came from, so the central form's
/// "Affected application" dropdown would be asking a question that is settled — and an iOS-only
/// defect is triaged by whoever owns this target. `config.yml` in the template directory links
/// back out for the reports that turn out to be a server problem.
///
/// The query-parameter names below are a contract with `.github/ISSUE_TEMPLATE/1-bug-report.yml`:
/// GitHub matches each one against a field `id` and *silently drops* any that doesn't match, so
/// renaming a field there turns the prefill off rather than breaking anything loudly.
enum BugReport {

    /// `owner/repo` holding the issue form.
    static let repository = "wcherry/neutrino_drive_ios_mobile"

    /// Filename of the form within `.github/ISSUE_TEMPLATE/`.
    static let template = "1-bug-report.yml"

    // MARK: - URL

    /// The new-issue URL, prefilled with what this build can determine about itself.
    ///
    /// Prefilled rather than gathered silently: every value lands in a form field the user reads
    /// and can edit before they submit. A bug report is a public document, and the person filing
    /// it should be able to see exactly what it is about to say about their phone.
    static var issueURL: URL {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "template", value: template),
            URLQueryItem(name: "version", value: appVersion),
            URLQueryItem(name: "ios", value: systemVersion),
            URLQueryItem(name: "device", value: deviceModel),
            URLQueryItem(name: "install", value: installSource),
            URLQueryItem(name: "server", value: serverKind)
        ]
        // `repository` is a compile-time constant of URL-safe characters and URLComponents
        // percent-encodes the values, so the optional is unconditional in practice. The fallback
        // exists so that a surprise here costs the user the prefill rather than the bug report.
        return components?.url
            ?? URL(string: "https://github.com/\(repository)/issues/new/choose")!
    }

    // MARK: - Diagnostics

    /// `1.0.0 (8)` — marketing version with the build number, which is the half that matters:
    /// TestFlight ships many builds under one marketing version, and "1.0.0" alone cannot tell
    /// a fixed build from the one that still has the bug.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }

    /// `iOS 18.2`, or whatever the OS calls itself — iPadOS and visionOS report their own names.
    static var systemVersion: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    /// The hardware identifier — `iPhone15,3` rather than `UIDevice.model`, which answers
    /// "iPhone" on every device capable of filing this report and so tells triage nothing.
    /// The identifier names the chip, the screen size and the cameras.
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    /// Best guess at where this build came from, spelled to match the form's dropdown options.
    ///
    /// A guess, not a fact: the sandbox receipt is what a TestFlight build and a build run from
    /// Xcode have in common, so a release build installed by Xcode reads as TestFlight. It is
    /// right far more often than not, and it lands in a field the user can correct.
    static var installSource: String {
        #if DEBUG
        return "Built from source in Xcode"
        #else
        let receipt = Bundle.main.appStoreReceiptURL?.lastPathComponent
        return receipt == "sandboxReceipt" ? "TestFlight" : "App Store"
        #endif
    }

    /// Which *kind* of server the app is pointed at — deliberately the category, never the address.
    ///
    /// A self-hosted Neutrino is often reachable only on a LAN, or behind a hostname its owner
    /// would rather not publish, and this string is going straight into a public issue. Triage
    /// needs to know that it is self-hosted; it does not need to know where.
    static var serverKind: String {
        let host = NeutrinoStorage.serverHost.lowercased()
        if host.contains("getneutrino.app") { return "getneutrino.app (hosted)" }
        if host.contains("localhost") || host.contains("127.0.0.1") {
            return "localhost / development"
        }
        return "Self-hosted"
    }
}

// MARK: - ReportBugButton

/// The "Report a Bug" menu item.
///
/// A view rather than a bare `Button` at the call site so the label, the icon and the prefilling
/// are spelled once: the six Neutrino apps each carry their own copy of this file, and an item
/// that reads differently in Sheets than it does in Drive is the kind of drift nobody notices.
///
/// Opens in the browser rather than posting anything itself. Filing an issue needs a GitHub
/// account and the user's own words, and an in-app form that silently failed to submit would be
/// worse than no button at all.
struct ReportBugButton: View {

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(BugReport.issueURL)
        } label: {
            Label("Report a Bug", systemImage: "ladybug")
        }
    }
}
