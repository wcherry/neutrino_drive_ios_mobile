import SwiftUI
import UIKit
import CoreSpotlight

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
    @StateObject private var spotlightService = SpotlightIndexService()

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
                    .environmentObject(spotlightService)

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

                // The Files-app location exists only while the user is signed in *and* holds
                // keys — see `FileProviderDomainService` for why both are required.
                await FileProviderDomainService.synchronize(
                    isAuthenticated: authService.isAuthenticated,
                    hasKeys: KeyImportService.hasStoredKeys()
                )
            }
            .onChange(of: authService.isAuthenticated) { isAuthenticated in
                Task {
                    await FileProviderDomainService.synchronize(
                        isAuthenticated: isAuthenticated,
                        hasKeys: KeyImportService.hasStoredKeys()
                    )
                }
                if !isAuthenticated {
                    // Signing out must take the Spotlight entries with it. Leaving indexed
                    // filenames behind after logout would mean a signed-out device still
                    // answering system searches with the previous user's file names.
                    spotlightService.deindexAll()
                }
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
    @EnvironmentObject var spotlightService: SpotlightIndexService

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
                    // `IncomingDocument.consume` takes the security scope, coordinates the
                    // read, and deletes the source **only** when it is a copy iOS placed in
                    // this app's Inbox.
                    //
                    // The previous `Data(contentsOf:)` + unconditional `removeItem` was safe
                    // only while `LSSupportsOpeningDocumentsInPlace` was `false`. Now that it
                    // is `true`, this URL can be the user's own file in iCloud Drive, and the
                    // old code would have deleted it as a side effect of importing a key from
                    // it. See `IncomingDocument` for the full account.
                    let data = try IncomingDocument.consume(url: url)
                    let bundle = try KeyImportService.importKey(from: data)
                    KeyImportService.storeKeys(bundle)
                    openInAlertMessage = "Encryption key v\(bundle.keyVersion) imported successfully."
                } catch {
                    openInAlertMessage = error.localizedDescription
                }
                showOpenInAlert = true
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            // A Spotlight result. `driveItemID(from:)` returns nil for any activity that is not
            // one of ours, so an unrelated continuation cannot be misread as a file to open.
            guard let itemID = SpotlightIndexService.driveItemID(from: activity) else { return }
            NotificationCenter.default.post(name: .openDriveItemFromSpotlight,
                                            object: nil, userInfo: ["itemID": itemID])
        }
        .alert("Key Import", isPresented: $showOpenInAlert) {
            Button("OK") {}
        } message: {
            Text(openInAlertMessage)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a Spotlight result is opened. Carries `userInfo["itemID"]`.
    ///
    /// A notification rather than a binding threaded down through the view tree: the deep-link
    /// target depends on which section is on screen, and the browser already owns that state.
    static let openDriveItemFromSpotlight = Notification.Name("nd.openDriveItemFromSpotlight")
}
