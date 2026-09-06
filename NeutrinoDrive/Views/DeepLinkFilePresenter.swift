import SwiftUI
import QuickLook
import NeutrinoCore
import NeutrinoAuth

// MARK: - DeepLinkFilePresenter

/// Opens the file an inbound Universal Link named.
///
/// Presentation is deliberately modal rather than a push into the Files tab: the link's file may
/// live in a folder that is not on screen — or in nobody's listing at all, if it was shared — so
/// there is no navigation stack to restore. A sheet shows the requested file and leaves whatever
/// the user was doing underneath it untouched.
///
/// The work only starts once the user is signed in. A link that arrives at the login screen sits in
/// the router until it is, which is what makes a cold launch from a link behave the same as a tap
/// in a running app.
struct DeepLinkFilePresenter: ViewModifier {

    // MARK: - Input

    @ObservedObject var router: DeepLinkRouter

    // MARK: - Environment

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var driveService: DriveService

    // MARK: - State

    @StateObject private var downloadService = DownloadService()
    @State private var viewerItem: DriveItem?
    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var isResolving = false

    // MARK: - Body

    func body(content: Content) -> some View {
        content
            // Keyed on both, so the pending link is picked up either when it arrives or when a
            // link that arrived pre-login finally has a session to run against.
            .task(id: taskID) { await resolvePending() }
            .overlay { if isResolving { resolvingOverlay } }
            .sheet(item: $viewerItem) { item in
                NeutrinoFileViewer(item: item)
            }
            .quickLookPreview($previewURL)
            .alert("Couldn\u{2019}t Open File", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var taskID: String {
        "\(authService.isAuthenticated)-\(router.pending?.id ?? "none")"
    }

    private var resolvingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            ProgressView("Opening\u{2026}")
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Resolution

    private func resolvePending() async {
        guard FeatureFlags.companionAppLinks else { return }
        guard authService.isAuthenticated, router.pending != nil else { return }
        guard let destination = router.consume() else { return }

        isResolving = true
        defer { isResolving = false }

        do {
            let item = try await driveService.fetchItem(id: destination.fileID)
            present(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Same two ways of opening a file the browser offers, chosen the same way — a link should not
    /// be a third kind of "open".
    private func present(_ item: DriveItem) {
        if FeatureFlags.viewNeutrinoFiles
            && (item.isNeutrinoNativeFormat || NeutrinoAppLink.kind(forMIME: item.mimeType) != nil) {
            viewerItem = item
            return
        }
        Task {
            do {
                previewURL = try await downloadService.download(
                    fileID: item.id,
                    fileName: item.name,
                    mimeType: item.mimeType
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - View

extension View {
    /// Presents whatever file an inbound Neutrino app link asked for.
    func presentingDeepLinkedFile(router: DeepLinkRouter) -> some View {
        modifier(DeepLinkFilePresenter(router: router))
    }
}
