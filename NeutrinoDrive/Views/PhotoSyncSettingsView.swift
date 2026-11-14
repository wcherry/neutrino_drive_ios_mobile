import SwiftUI
import Photos

// MARK: - PhotoSyncSettingsView

/// Detail screen for the opt-in photo auto-sync feature: enable toggle, destination folder,
/// network/power constraints, live status, and manual "Sync Now" / "Retry Failed" actions.
struct PhotoSyncSettingsView: View {
    @ObservedObject var photoSyncService: PhotoSyncService

    @State private var folderNameDraft: String = ""
    @State private var showDeniedAlert = false

    var body: some View {
        Form {
            Section {
                Toggle("Back Up My Photos", isOn: $photoSyncService.isEnabled)
                if photoSyncService.authorizationStatus == .limited {
                    limitedAccessRow
                }
            } footer: {
                Text(enableFooterText)
            }

            if photoSyncService.isEnabled {
                Section {
                    TextField("Folder Name", text: $folderNameDraft)
                        .onAppear { folderNameDraft = photoSyncService.folderName }
                        .onSubmit { photoSyncService.folderName = folderNameDraft }
                        .onChange(of: folderNameDraft) { newValue in
                            photoSyncService.folderName = newValue
                        }
                } header: {
                    Text("Destination")
                } footer: {
                    Text("Photos are uploaded to this folder in your Drive. Encrypted before they leave your device.")
                }

                Section {
                    Picker("Include Older Photos", selection: backfillWindow) {
                        ForEach(PhotoBackfillWindow.allCases) { window in
                            Text(window.label).tag(window)
                        }
                    }
                    if photoSyncService.pendingCount > 0 {
                        HStack {
                            Text("Queued")
                            Spacer()
                            Text("\(photoSyncService.pendingCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Existing Library")
                } footer: {
                    Text(backfillFooterText)
                }

                Section {
                    Toggle("Include Videos", isOn: Binding(
                        get: { photoSyncService.includeVideos },
                        set: { photoSyncService.includeVideos = $0 }
                    ))
                    // Same label and default as Neutrino Photos' own setting, so the two apps
                    // describe the same thing the same way.
                    Toggle("Keep Live Photo Motion", isOn: Binding(
                        get: { photoSyncService.keepLivePhotoMotion },
                        set: { photoSyncService.keepLivePhotoMotion = $0 }
                    ))
                    Toggle("Use Wi-Fi Only", isOn: Binding(
                        get: { photoSyncService.wifiOnly },
                        set: { photoSyncService.wifiOnly = $0 }
                    ))
                    Toggle("Only While Charging", isOn: Binding(
                        get: { photoSyncService.whileChargingOnly },
                        set: { photoSyncService.whileChargingOnly = $0 }
                    ))
                } header: {
                    Text("Constraints")
                } footer: {
                    Text("Live Photo motion is the short clip behind a Live Photo, roughly the size "
                         + "of the photo again. It's uploaded next to the photo even with Include "
                         + "Videos off. Turning it off doesn't remove clips already uploaded.")
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(photoSyncService.status.displayText)
                            .foregroundStyle(.secondary)
                    }
                    // Prepared and handed to iOS, which carries the transfer on its own schedule
                    // — "waiting for iOS", as opposed to "not started" (#38).
                    if photoSyncService.handedOffCount > 0 {
                        HStack {
                            Text("Waiting on iOS")
                            Spacer()
                            Text("\(photoSyncService.handedOffCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if let lastSyncedAt = photoSyncService.lastSyncedAt {
                        HStack {
                            Text("Last Synced")
                            Spacer()
                            Text(lastSyncedAt, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Whether iOS is waking the app at all — the one fact that tells apart
                    // "the background run is failing" from "the background run never happens".
                    HStack {
                        Text("Last Background Run")
                        Spacer()
                        if let lastBackgroundRunAt = photoSyncService.lastBackgroundRunAt {
                            Text(lastBackgroundRunAt, style: .relative)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Never")
                                .foregroundStyle(.secondary)
                        }
                    }
                    // The Photos extension's own wake-ups (#38, Phase 2). Shown while the
                    // feature is being tried on devices: how often iOS runs it is the open
                    // question that decides whether it can be turned on for everyone.
                    if FeatureFlags.photoUploadExtension {
                        let runs = photoSyncService.extensionRuns
                        let lastDay = runs.filter { $0.startedAt > Date().addingTimeInterval(-86_400) }
                        HStack {
                            Text("Photos Wake-ups")
                            Spacer()
                            if let last = runs.last {
                                Text("\(lastDay.count) today · \(last.startedAt, style: .relative)")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Never")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let last = runs.last {
                            Text(Self.describe(last))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if photoSyncService.lastBackgroundRunAt == nil {
                        Text("iOS decides when to run background sync, and it won't run it at all "
                             + "for an app that was force-quit from the app switcher. Leave Drive "
                             + "running in the background rather than swiping it away.")
                    }
                }

                Section {
                    Button("Sync Now") {
                        photoSyncService.syncNow()
                    }
                    if !photoSyncService.failedEntries.isEmpty {
                        Button("Retry Failed") {
                            photoSyncService.retryFailed()
                        }
                    }
                } footer: {
                    Text("Turning photo backup off leaves already-uploaded photos in Drive.")
                }

                neutrinoPhotosSection
                motionSection
                repairSection
            }
        }
        .navigationTitle("Photo Sync")
        .onChange(of: photoSyncService.authorizationStatus) { newValue in
            if newValue == .denied || newValue == .restricted {
                showDeniedAlert = true
            }
        }
        .alert("Photo Access Needed", isPresented: $showDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Neutrino Drive needs photo library access to back up new photos. Enable access in iOS Settings.")
        }
    }

    // MARK: - Neutrino Photos

    /// Registers backed-up photos with the Neutrino Photos library (#45). Opt-in.
    @ViewBuilder
    private var neutrinoPhotosSection: some View {
        Section {
            Toggle("Show in Neutrino Photos", isOn: Binding(
                get: { photoSyncService.showInNeutrinoPhotos },
                set: { photoSyncService.showInNeutrinoPhotos = $0 }
            ))
            if photoSyncService.showInNeutrinoPhotos {
                Button("Add Earlier Photos") {
                    Task { await photoSyncService.addEarlierPhotosToNeutrinoPhotos() }
                }
                .disabled(photoSyncService.photosRegistrationState.isRunning)

                switch photoSyncService.photosRegistrationState {
                case .running:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Adding\u{2026}").foregroundStyle(.secondary)
                    }
                case .finished(let report):
                    Text(report.summary).foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                case .idle:
                    if let last = photoSyncService.lastPhotosRegistration {
                        Text(last.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Neutrino Photos")
        } footer: {
            Text("Also list backed-up photos in Neutrino Photos, on the web and on your devices, "
                 + "with Live Photos playing as Live Photos. Neutrino Photos can back up this "
                 + "library itself: use one or the other, not both, or each photo is stored twice. "
                 + "Add Earlier Photos takes in what was backed up before you turned this on.")
        }
    }

    // MARK: - Live Photo motion

    /// Adds the motion to Live Photos backed up as stills only. See
    /// ``PhotoSyncService/checkLivePhotoMotionBackfill()``.
    @ViewBuilder
    private var motionSection: some View {
        Section {
            Button("Add Live Photo Motion") {
                Task { await photoSyncService.checkLivePhotoMotionBackfill() }
            }
            .disabled(photoSyncService.motionBackfillState.isBusy || !photoSyncService.keepLivePhotoMotion)

            switch photoSyncService.motionBackfillState {
            case .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking\u{2026}").foregroundStyle(.secondary)
                }
            case .awaitingConfirmation(let count, _):
                Text("\(count) Live Photo\(count == 1 ? "" : "s") to update")
                    .foregroundStyle(.secondary)
            case .finished(let report):
                Text(report.summary).foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            case .idle:
                if let last = photoSyncService.lastMotionBackfill {
                    HStack {
                        Text("Last Run")
                        Spacer()
                        Text(last.finishedAt, style: .relative).foregroundStyle(.secondary)
                    }
                    Text(last.summary).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Live Photo Motion")
        } footer: {
            Text("Live Photos backed up before this version have their photo but not their motion. "
                 + "This uploads the motion for the ones still on this device, next to each photo. "
                 + "Photos you've removed from the backup folder are left alone. Safe to run more "
                 + "than once, and uploads follow the constraints above.")
        }
        .confirmationDialog(motionConfirmationTitle, isPresented: motionConfirmationShown,
                            titleVisibility: .visible) {
            Button("Add Motion") {
                Task { await photoSyncService.confirmLivePhotoMotionBackfill() }
            }
            Button("Cancel", role: .cancel) {
                photoSyncService.cancelLivePhotoMotionBackfill()
            }
        } message: {
            Text(motionConfirmationMessage)
        }
    }

    private var motionConfirmationShown: Binding<Bool> {
        Binding(
            get: {
                if case .awaitingConfirmation = photoSyncService.motionBackfillState { return true }
                return false
            },
            set: { shown in
                // Dismissed without a choice (tapping outside) is a cancel.
                if !shown, case .awaitingConfirmation = photoSyncService.motionBackfillState {
                    photoSyncService.cancelLivePhotoMotionBackfill()
                }
            }
        )
    }

    private var motionConfirmationTitle: String {
        guard case .awaitingConfirmation(let count, _) = photoSyncService.motionBackfillState else { return "" }
        return "Add motion to \(count) Live Photo\(count == 1 ? "" : "s")?"
    }

    private var motionConfirmationMessage: String {
        guard case .awaitingConfirmation(_, let bytes) = photoSyncService.motionBackfillState else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let network = photoSyncService.wifiOnly ? "Uploads on Wi-Fi only." : "Uploads on any network."
        return "About \(size). \(network)"
    }

    // MARK: - Repair photo dates

    /// The one-time pass that gives photos backed up before the capture-date fix the date they
    /// were actually taken. See ``PhotoSyncService/repairPhotoDates()``.
    @ViewBuilder
    private var repairSection: some View {
        Section {
            Button("Repair Photo Dates") {
                Task { await photoSyncService.repairPhotoDates() }
            }
            .disabled(photoSyncService.dateRepairState.isRunning)

            switch photoSyncService.dateRepairState {
            case .running(let examined):
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking\(examined > 0 ? " — \(examined) so far" : "…")")
                        .foregroundStyle(.secondary)
                }
            case .finished(let report):
                Text(report.summary)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            case .idle:
                if let last = photoSyncService.lastDateRepair {
                    HStack {
                        Text("Last Repair")
                        Spacer()
                        Text(last.finishedAt, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                    Text(last.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Repair")
        } footer: {
            Text(repairFooterText)
        }
    }

    private var repairFooterText: String {
        "Photos backed up before this version are dated by the upload, not by when they were "
        + "taken. This looks each one up in your photo library and puts the real date back. "
        + "Safe to run more than once, and it honours the constraints above. Photos no longer "
        + "on this device, or backed up from another one, can't be reached."
    }

    // MARK: - Backfill window

    private var backfillWindow: Binding<PhotoBackfillWindow> {
        Binding(
            get: { PhotoBackfillWindow(days: photoSyncService.backfillDays) },
            set: { photoSyncService.backfillDays = $0.days }
        )
    }

    private var enableFooterText: String {
        let window = PhotoBackfillWindow(days: photoSyncService.backfillDays)
        switch window {
        case .off:
            return "Photos taken from now on will be backed up. Existing photos in your library are not uploaded."
        case .all:
            return "Photos taken from now on will be backed up, along with your entire existing library."
        default:
            // "Last 30 Days" → "the last 30 days".
            return "Photos taken from now on will be backed up, along with those from the "
                 + window.label.lowercased() + "."
        }
    }

    private var backfillFooterText: String {
        switch PhotoBackfillWindow(days: photoSyncService.backfillDays) {
        case .off:
            return "Reach back into photos you already have. Widening this queues everything in "
                 + "the window that isn't backed up yet; narrowing it later leaves what has "
                 + "already been uploaded in Drive."
        case .all:
            return "Your whole library will be queued — this can be thousands of photos and a "
                 + "lot of data. New photos are still backed up first; older ones follow."
        default:
            return "Older photos are queued behind new ones, so a backlog never delays the "
                 + "photo you just took."
        }
    }

    private var limitedAccessRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Limited photo access — only selected photos will back up.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
            Button("Manage Selection") {
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
                }
            }
            .font(.footnote)
        }
    }

    /// One line about the extension's latest run: what it did, or why it did nothing.
    static func describe(_ run: PhotoExtensionRun) -> String {
        let seconds = String(format: "%.1fs", run.duration)
        if let skipped = run.skipped {
            return "Last run (\(seconds)): did nothing — \(skipped)."
        }
        var parts = ["sent \(run.handedOff)", "\(run.completed) finished"]
        if run.enqueued > 0 { parts.append("\(run.enqueued) new") }
        if run.awaitingDownload > 0 { parts.append("\(run.awaitingDownload) waiting for iCloud") }
        if run.leftForApp > 0 { parts.append("\(run.leftForApp) left for the app") }
        if run.failed > 0 { parts.append("\(run.failed) failed") }
        if run.terminated { parts.append("stopped by iOS") }
        return "Last run (\(seconds)): " + parts.joined(separator: ", ") + "."
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PhotoSyncSettingsView(photoSyncService: PhotoSyncService())
    }
}
