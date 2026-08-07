import SwiftUI
import UIKit

// MARK: - AppDelegate

/// Exists for exactly one reason: SwiftUI's `App` lifecycle has no hook for
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`, and without that
/// callback a background transfer that completes while the app is suspended can never be
/// delivered — iOS relaunches the process, finds nobody listening, and gives up.
///
/// It has no other responsibility; everything else stays in the SwiftUI `App`.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTransferService.backgroundIdentifier else {
            completionHandler()
            return
        }
        // Touching `.shared` here is what reconnects the process to the existing background
        // session so its queued delegate callbacks can be replayed. The handler is invoked from
        // `urlSessionDidFinishEvents(forBackgroundURLSession:)` once that replay is done.
        BackgroundTransferService.shared.handleBackgroundEvents(completionHandler: completionHandler)
    }
}

// MARK: - NeutrinoDriveApp

@main
struct NeutrinoDriveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var authService = AuthService()
    @StateObject private var driveService = DriveService()
    @StateObject private var offlineService = OfflineService()
    @StateObject private var uploadService = UploadService()
    @StateObject private var photoSyncService = PhotoSyncService()
    @StateObject private var biometricService = BiometricAuthService()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must be registered before the app finishes launching. No-ops when
        // FeatureFlags.photoAutoSync is false. Accessing the StateObject's storage
        // directly (rather than the `photoSyncService` property) is safe here — this
        // only invokes a plain method, it doesn't participate in view invalidation.
        _photoSyncService.wrappedValue.registerBackgroundTask()

        // Relocates existing Keychain items into the shared access group so the share
        // extension can read them. No-op when the App Group entitlement is absent.
        KeychainService.migrateToSharedAccessGroupIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootContentView()
                    .environmentObject(authService)
                    .environmentObject(driveService)
                    .environmentObject(offlineService)
                    .environmentObject(photoSyncService)
                    .environmentObject(biometricService)

                if biometricService.shouldPresentOverlay {
                    LockScreenView(biometricService: biometricService)
                        .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: biometricService.shouldPresentOverlay)
            .task {
                driveService.authService = authService
                uploadService.driveService = driveService
                photoSyncService.configure(driveService: driveService, uploadService: uploadService)
                photoSyncService.start()
                biometricService.lockOnLaunch()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                photoSyncService.scheduleBackgroundTask()
                biometricService.sceneDidEnterBackground()
            case .inactive:
                // Fires *before* .background and is when iOS captures the app-switcher
                // snapshot — obscuring here, not there, is what keeps file names out of it.
                biometricService.sceneDidBecomeInactive()
            case .active:
                biometricService.sceneDidBecomeActive()
            @unknown default:
                break
            }
        }
    }
}

// MARK: - RootContentView

/// Wraps the authenticated/unauthenticated content and handles "Open In" URLs.
private struct RootContentView: View {
    @EnvironmentObject var authService: AuthService

    @StateObject private var deepLinkRouter = DeepLinkRouter()

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
        .presentingDeepLinkedFile(router: deepLinkRouter)
        .onOpenURL { url in
            // Universal Links first: they are `https`, so they can never be confused with the
            // key-file "Open In" flow below, which only ever sees `file://` URLs.
            if FeatureFlags.companionAppLinks, deepLinkRouter.handle(url) { return }

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
