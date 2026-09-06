import UIKit
import UniformTypeIdentifiers
import os.log
import NeutrinoCore

/// Host view controller for the "Share → Neutrino Drive" extension.
///
/// Kept in UIKit rather than SwiftUI on purpose: a share extension's whole job is to show a
/// small status surface and get out of the way, and `NSExtensionContext` completion is a
/// UIKit-lifecycle concern. There is no navigation, no file browsing, and no login here.
///
/// ## What this does not do
///
/// - **No biometric gate.** This is a write-only path — it never displays existing Drive
///   content. A locked share sheet with no way to authenticate would be strictly worse than an
///   unauthenticated upload of a file the user just explicitly chose to send.
/// - **No login or key import.** The extension cannot present the app's flows. Missing
///   credentials or keys produce an explanation and an "Open Neutrino Drive" button.
/// - **No background continuation.** The extension's process dies when it is dismissed, taking
///   any `URLSession` with it, so uploads run inline while the sheet is on screen and the sheet
///   stays up until they finish.
final class ShareViewController: UIViewController {

    /// The extension is a separate process with its own launch, so it configures the shared
    /// package itself — the app's `init()` never runs here. Same `nd.*` namespace and same App
    /// Group, which is exactly what lets it read the token and key the app imported.
    private static let configured: Void = {
        NeutrinoApp.configure(.drive)
    }()


    private let coordinator = ShareUploadCoordinator()
    private let logger = Logger(subsystem: "com.neutrino.drive.share", category: "ShareViewController")

    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let primaryButton = UIButton(type: .system)

    private var isFinished = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()

        guard FeatureFlags.shareExtension else {
            present(title: "Unavailable",
                    detail: "Sharing to Neutrino Drive is turned off in this build.",
                    buttonTitle: "Close", action: { [weak self] in self?.finish(cancelled: true) })
            return
        }

        let attachments = Self.flattenAttachments(from: extensionContext?.inputItems ?? [])

        if let error = coordinator.checkPreconditions(attachmentCount: attachments.count) {
            present(title: "Can't Upload",
                    detail: error.localizedDescription,
                    buttonTitle: "Close", action: { [weak self] in self?.finish(cancelled: true) })
            return
        }

        Task { await runUpload(attachments) }
    }

    // MARK: - Attachment flattening

    /// Flattens every `NSExtensionItem`'s attachments into one ordered list.
    ///
    /// Multi-select shares can arrive either as several input items with one attachment each,
    /// or as one input item with several attachments, depending on the sending app. Flattening
    /// both shapes into a single list is what makes "share five photos at once" work regardless
    /// of which app they came from.
    ///
    /// The first type identifier the provider registers is used; `.fileURL`/`.item`/`.data` are
    /// preferred where present because they yield the original bytes rather than a rendered
    /// representation.
    static func flattenAttachments(from inputItems: [Any]) -> [ShareAttachment] {
        var result: [ShareAttachment] = []
        for case let item as NSExtensionItem in inputItems {
            for provider in item.attachments ?? [] {
                guard let typeIdentifier = preferredTypeIdentifier(for: provider) else { continue }
                result.append(ItemProviderAttachment(provider: provider, typeIdentifier: typeIdentifier))
            }
        }
        return result
    }

    private static func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
        let preferred = [UTType.fileURL, .image, .movie, .pdf, .data, .item].map(\.identifier)
        for candidate in preferred where provider.hasItemConformingToTypeIdentifier(candidate) {
            return candidate
        }
        return provider.registeredTypeIdentifiers.first
    }

    // MARK: - Upload run

    private func runUpload(_ attachments: [ShareAttachment]) async {
        spinner.startAnimating()
        statusLabel.text = attachments.count == 1 ? "Encrypting and uploading…" : "Uploading 1 of \(attachments.count)…"
        detailLabel.text = "Files are encrypted on this device before they are sent."
        primaryButton.isHidden = true

        let results = await coordinator.run(attachments: attachments) { [weak self] index, total in
            Task { @MainActor in
                guard total > 1 else { return }
                self?.statusLabel.text = "Uploading \(index) of \(total)…"
            }
        }

        spinner.stopAnimating()
        presentResults(results)
    }

    private func presentResults(_ results: [ShareItemResult]) {
        let succeeded = results.filter { $0.outcome.isSuccess }
        let failed = results.filter { !$0.outcome.isSuccess }

        if failed.isEmpty {
            present(title: succeeded.count == 1 ? "Uploaded" : "Uploaded \(succeeded.count) files",
                    detail: "Saved to your Neutrino Drive, end-to-end encrypted.",
                    buttonTitle: "Done",
                    action: { [weak self] in self?.finish(cancelled: false) })
            // Auto-dismiss on unqualified success — nobody wants to tap "Done" after a share.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.finish(cancelled: false)
            }
            return
        }

        // Name the failures individually. "Some uploads failed" tells the user nothing about
        // which of their five photos they need to re-send.
        let failureLines = failed.map { result -> String in
            if case .failed(let message) = result.outcome {
                return "\u{2022} \(result.name): \(message)"
            }
            return "\u{2022} \(result.name)"
        }
        var detail = failureLines.joined(separator: "\n")
        if !succeeded.isEmpty {
            detail = "\(succeeded.count) uploaded.\n\n" + detail
        }
        present(title: succeeded.isEmpty ? "Upload Failed" : "Partly Uploaded",
                detail: detail,
                buttonTitle: "Close",
                action: { [weak self] in self?.finish(cancelled: succeeded.isEmpty) })
    }

    // MARK: - Completion

    private func finish(cancelled: Bool) {
        guard !isFinished else { return }
        isFinished = true
        if cancelled {
            extensionContext?.cancelRequest(withError: NSError(domain: "com.neutrino.drive.share", code: 0))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    // MARK: - UI

    private func present(title: String, detail: String, buttonTitle: String, action: @escaping () -> Void) {
        spinner.stopAnimating()
        statusLabel.text = title
        detailLabel.text = detail
        primaryButton.isHidden = false
        primaryButton.setTitle(buttonTitle, for: .normal)
        primaryAction = action
    }

    private var primaryAction: (() -> Void)?

    @objc private func primaryButtonTapped() {
        primaryAction?()
    }

    private func configureUI() {
        view.backgroundColor = .systemBackground

        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        primaryButton.addTarget(self, action: #selector(primaryButtonTapped), for: .touchUpInside)
        primaryButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, detailLabel, primaryButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }
}
