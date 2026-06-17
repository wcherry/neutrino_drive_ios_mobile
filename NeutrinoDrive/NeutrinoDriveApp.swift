import SwiftUI

@main
struct NeutrinoDriveApp: App {
    @StateObject private var authService = AuthService()

    var body: some Scene {
        WindowGroup {
            RootContentView()
                .environmentObject(authService)
        }
    }
}

// MARK: - RootContentView

/// Wraps the authenticated/unauthenticated content and handles "Open In" URLs.
private struct RootContentView: View {
    @EnvironmentObject var authService: AuthService

    @State private var showOpenInAlert = false
    @State private var openInAlertMessage = ""

    var body: some View {
        Group {
            if authService.isAuthenticated {
                ContentView()
                    .environmentObject(authService)
            } else {
                LoginView()
                    .environmentObject(authService)
            }
        }
        .onOpenURL { url in
            guard url.pathExtension == "json" else { return }
            Task { @MainActor in
                do {
                    let data = try Data(contentsOf: url)
                    let bundle = try KeyImportService.importKey(from: data)
                    KeyImportService.storeKeys(bundle)
                    try? FileManager.default.removeItem(at: url)
                    openInAlertMessage = "Encryption key v\(bundle.keyVersion) imported successfully."
                } catch {
                    openInAlertMessage = error.localizedDescription
                }
                showOpenInAlert = true
            }
        }
        .alert("Key Import", isPresented: $showOpenInAlert) {
            Button("OK") {}
        } message: {
            Text(openInAlertMessage)
        }
    }
}
