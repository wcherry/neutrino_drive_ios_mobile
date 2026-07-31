import SwiftUI

@main
struct NeutrinoDriveApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var driveService = DriveService()
    @StateObject private var uploadService = UploadService()
    @StateObject private var photoSyncService = PhotoSyncService()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must be registered before the app finishes launching. No-ops when
        // FeatureFlags.photoAutoSync is false. Accessing the StateObject's storage
        // directly (rather than the `photoSyncService` property) is safe here — this
        // only invokes a plain method, it doesn't participate in view invalidation.
        _photoSyncService.wrappedValue.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootContentView()
                .environmentObject(authService)
                .environmentObject(driveService)
                .environmentObject(photoSyncService)
                .task {
                    driveService.authService = authService
                    uploadService.driveService = driveService
                    photoSyncService.configure(driveService: driveService, uploadService: uploadService)
                    photoSyncService.start()
                }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                photoSyncService.scheduleBackgroundTask()
            }
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
