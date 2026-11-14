import SwiftUI
import CoreSpotlight
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
import NeutrinoUI
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
        // The Photos extension's uploads, finished while the extension was not running. iOS
        // brings them to the containing app; photo sync collects them from the orphan handler.
        if identifier == BackgroundTransferService.photosExtensionIdentifier {
            BackgroundTransferService.attachForDelivery(identifier: identifier,
                                                        completionHandler: completionHandler)
            return
        }
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

    // Built in `init()` rather than given default values here: defaults are evaluated before the
    // initializer body runs, and the shared services resolve their Keychain namespace through
    // `NeutrinoApp.current` the moment they are constructed.
    @StateObject private var authService: AuthService
    @StateObject private var driveService: DriveService
    @StateObject private var offlineService: OfflineService
    @StateObject private var uploadService: UploadService
    @StateObject private var photoSyncService: PhotoSyncService
    @StateObject private var biometricService: BiometricAuthService
    @StateObject private var keyProvisioningService = KeyProvisioningService()
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var deviceKeyRepair: DeviceKeyRepairService
    @StateObject private var spotlightService = SpotlightIndexService()
    @StateObject private var streamingService = StreamingPlaybackService()
    @StateObject private var smartOffline = SmartOfflineSyncService()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything else, and before the Keychain migration below reads the App Group out of
        // it. `nd.*` is what previous builds wrote, so this reads the existing session and the
        // already-imported encryption key rather than starting cold.
        NeutrinoApp.configure(.drive)
        NeutrinoBrand.use(.drive)

        let auth = AuthService()
        let drive = DriveService()
        let upload = UploadService()
        let photoSync = PhotoSyncService()

        // Dependency wiring happens *here*, not in the scene's `.task`.
        //
        // iOS launches this process with no scene attached when it runs the photo-sync
        // `BGProcessingTask`, and it relaunches it the same way to deliver finished
        // background transfers. No scene means no view body, which means `.task` never
        // runs — so anything wired there does not exist on precisely the launches photo
        // sync depends on. Left unwired, `PhotoSyncService` has no `uploadPreparer` and no
        // `folderResolver`, so every background upload threw `notAuthenticated` and the
        // photo burned an attempt against its retry budget; after five it landed in
        // `failed`, recoverable only by tapping "Retry Failed" in Settings. The
        // user-visible symptom was that photos only ever uploaded with the app on screen.
        drive.authService = auth
        upload.driveService = drive
        photoSync.configure(driveService: drive, uploadService: upload, authService: auth)
        let keyRepair = DeviceKeyRepairService(transport: drive)

        _authService = StateObject(wrappedValue: auth)
        _driveService = StateObject(wrappedValue: drive)
        _offlineService = StateObject(wrappedValue: OfflineService())
        _uploadService = StateObject(wrappedValue: upload)
        _photoSyncService = StateObject(wrappedValue: photoSync)
        _deviceKeyRepair = StateObject(wrappedValue: keyRepair)
        _biometricService = StateObject(wrappedValue: BiometricAuthService(
            isFeatureEnabled: FeatureFlags.biometricLock,
            unlockReason: "Unlock Neutrino Drive to access your encrypted files."
        ))

        // Must be registered before the app finishes launching. No-ops when
        // FeatureFlags.photoAutoSync is false.
        photoSync.registerBackgroundTask()

        // The App Group is only resolvable once the config is installed, so re-probe before
        // relocating: `KeychainService` computes its access group at first touch.
        KeychainService.reloadAccessGroup()

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
                    .environmentObject(keyProvisioningService)
                    .environmentObject(deviceKeyRepair)
                    .environmentObject(networkMonitor)
                    .environmentObject(spotlightService)
                    .environmentObject(streamingService)
                    .environmentObject(smartOffline)

                if biometricService.shouldPresentOverlay {
                    LockScreenView(biometricService: biometricService)
                        .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: biometricService.shouldPresentOverlay)
            .task {
                // Services are wired in `init()`; what is left here genuinely needs the UI.
                photoSyncService.start()
                biometricService.lockOnLaunch()

                // The Files-app location exists only while the user is signed in *and* holds
                // keys — see `FileProviderDomainService` for why both are required.
                await FileProviderDomainService.synchronize(
                    isAuthenticated: authService.isAuthenticated,
                    hasKeys: KeyImportService.hasStoredKeys()
                )

                // Smart offline runs on foreground rather than from a background task: photo
                // sync already owns the background budget, and competing with it to prefetch a
                // convenience cache is a poor trade.
                await smartOffline.sync(offlineService: offlineService,
                                        downloadService: DownloadService(),
                                        driveService: driveService)

                // Finish any upload whose ciphertext committed but whose sealed key never
                // did. The key `PUT` runs on the foreground session, so an upload suspended
                // after its blob cannot complete itself — and a file the server believes is
                // encrypted, with no key ref, is unreadable by every client forever. The
                // sealed DEK is on disk; this is the first moment it can be sent.
                await uploadService.reconcilePendingUploadKeys()

                // Server switches every process here follows — chiefly whether uploads are
                // written as NEB1 (neutrino#318). Cached in the App Group for the extensions.
                await RemoteFeatureFlags.refresh()

                // Top up this device's retired keys from the account's key file. Enrolment already
                // does this, so on a healthy install it finds nothing; it is here for the device
                // enrolled before the key file existed, and for the one that was offline when its
                // key arrived. One request, and a failure is not worth surfacing — the next launch
                // tries again.
                KeyFileService.shared.authService = authService
                // Minting a key talks to the account's key directory, so it needs the same token
                // refresher as everything else.
                keyProvisioningService.authService = authService
                if authService.isAuthenticated && KeyImportService.hasStoredKeys() {
                    try? await KeyFileService.shared.restoreArchivedKeys()
                    // A key replaced from another device leaves this one sealing to the old key,
                    // and the files it sealed open nowhere else. Only this device can move them
                    // onto the account's key, and only until the old key is replaced, so it
                    // starts by itself rather than waiting to be found in Settings.
                    await deviceKeyRepair.checkAndRepair()
                }
            }
            .onChange(of: authService.isAuthenticated) { isAuthenticated in
                Task {
                    await FileProviderDomainService.synchronize(
                        isAuthenticated: isAuthenticated,
                        hasKeys: KeyImportService.hasStoredKeys()
                    )
                }
                if !isAuthenticated {
                    // An access history must not outlive the session that produced it.
                    FileAccessTracker.shared.reset()
                    // Signing out takes the Spotlight entries with it, so a signed-out device
                    // never answers system searches with the previous user's file names.
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
                // Also on every foreground, not only at launch: the share extension uploads
                // into the same App Group store and its process dies the moment the sheet is
                // dismissed, so returning to the app is often the first chance to finish what
                // it started.
                Task {
                    await uploadService.reconcilePendingUploadKeys()
                    await RemoteFeatureFlags.refresh()
                    if authService.isAuthenticated && KeyImportService.hasStoredKeys() {
                        await deviceKeyRepair.checkAndRepair()
                    }
                }
                // `.task` runs once, when the root view first appears — it does not fire
                // again on a return from background. Re-running `start()` here is what
                // replays the PhotoKit catch-up scan for everything captured while the app
                // was suspended; it is idempotent (the observer, the path monitor and the
                // drain loop all guard against a second entry).
                photoSyncService.start()
            @unknown default:
                break
            }
        }

        // Secondary scene (phase 6 multi-window): one window per open document on iPad, Stage
        // Manager and external displays. Declared unconditionally because `SceneBuilder` does not
        // accept conditionals; `FeatureFlags.multiWindow` gates the only `openWindow` call sites,
        // so with the flag off the scene is never instantiated.
        WindowGroup(id: DocumentWindowScene.identifier, for: DocumentWindowValue.self) { $value in
            Group {
                if let value {
                    DocumentWindowView(value: value)
                        .environmentObject(authService)
                        .environmentObject(driveService)
                        .environmentObject(offlineService)
                        .environmentObject(streamingService)
                        .environmentObject(smartOffline)
                } else {
                    ContentUnavailableCompat(
                        title: "No document",
                        message: "This window has nothing to show.",
                        systemImage: "doc"
                    )
                }
            }
        }
    }
}

// MARK: - RootContentView

/// Wraps the authenticated/unauthenticated content, handles "Open In" URLs, and asks a newly
/// signed-in device for the account's encryption key.
private struct RootContentView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var spotlightService: SpotlightIndexService

    @StateObject private var deepLinkRouter = DeepLinkRouter()

    @State private var showOpenInAlert = false
    @State private var openInAlertMessage = ""

    @State private var showsKeyRestore = false
    /// Offered once per launch. Somebody who dismissed it gets back through Settings › Encryption,
    /// and every file that needs the key still says so when opened.
    @State private var hasOfferedKeyRestore = false

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
                    // `IncomingDocument.consume` takes the security scope, coordinates the read, and
                    // deletes the source **only** when it is a copy iOS placed in this app's Inbox.
                    // With `LSSupportsOpeningDocumentsInPlace` on, this URL can be the user's own
                    // file in iCloud Drive, which the old unconditional `removeItem` would delete.
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
            // A Spotlight result. `driveItemID(from:)` is nil for any activity that is not ours.
            guard let itemID = SpotlightIndexService.driveItemID(from: activity) else { return }
            NotificationCenter.default.post(name: .openDriveItemFromSpotlight,
                                            object: nil, userInfo: ["itemID": itemID])
        }
        .alert("Key Import", isPresented: $showOpenInAlert) {
            Button("OK") {}
        } message: {
            Text(openInAlertMessage)
        }
        .sheet(isPresented: $showsKeyRestore) {
            KeyRestorePromptView(isPresented: $showsKeyRestore)
        }
        // At launch for a session restored from the Keychain…
        .task { offerKeyRestoreIfNeeded() }
        // …and on a fresh sign-in, which the launch-time check above misses.
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            guard isAuthenticated else {
                hasOfferedKeyRestore = false
                return
            }
            offerKeyRestoreIfNeeded()
        }
    }

    /// Asks for the account's key when this device has none.
    ///
    /// Unlike the apps that carry a server-side vault, there is nothing to ask the server: Drive's
    /// key is created on a client and never transmitted, so "is there a key here" is the whole
    /// question and a Keychain read is the whole answer.
    private func offerKeyRestoreIfNeeded() {
        guard authService.isAuthenticated, !hasOfferedKeyRestore else { return }
        guard !KeyImportService.hasStoredKeys() else { return }
        hasOfferedKeyRestore = true
        showsKeyRestore = true
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a Spotlight result is opened. Carries `userInfo["itemID"]`; the browser, which
    /// owns which section is on screen, does the navigating.
    static let openDriveItemFromSpotlight = Notification.Name("nd.openDriveItemFromSpotlight")
}
