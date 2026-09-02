import SwiftUI
import WebKit
import NeutrinoCore
import NeutrinoAuth

// MARK: - NeutrinoFileViewer

/// Presents a Neutrino-native file (Doc, Sheet, Slide, Diagram, or Drawing)
/// inside a full-screen WKWebView. After the web app loads, the current Bearer
/// token is injected into localStorage so the web app can authenticate API
/// calls without a separate browser login session.
struct NeutrinoFileViewer: View {

    let item: DriveItem

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NeutrinoWebView(fileID: item.id)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - NeutrinoWebView

private struct NeutrinoWebView: UIViewRepresentable {

    let fileID: String

    private var viewerURL: URL? {
        let host = UserDefaults.standard.string(forKey: AuthService.serverHostKey)
                    ?? AuthService.defaultHost
        return URL(string: "\(host)/files/\(fileID)")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        if let url = viewerURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            injectToken(into: webView)
        }

        private func injectToken(into webView: WKWebView) {
            guard
                let token = KeychainService.load(forKey: AuthService.accessTokenKey),
                let tokenData = try? JSONEncoder().encode(token),
                let tokenLiteral = String(data: tokenData, encoding: .utf8)
            else { return }

            // Inject the Bearer token into localStorage so the Neutrino web app
            // can pick it up for its API calls and decryption pipeline.
            let js = """
            (function() {
                try {
                    localStorage.setItem('nd_access_token', \(tokenLiteral));
                    window.dispatchEvent(new CustomEvent('nd:token_injected'));
                } catch (_) {}
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
