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

                Section("Constraints") {
                    Toggle("Include Videos", isOn: Binding(
                        get: { photoSyncService.includeVideos },
                        set: { photoSyncService.includeVideos = $0 }
                    ))
                    Toggle("Use Wi-Fi Only", isOn: Binding(
                        get: { photoSyncService.wifiOnly },
                        set: { photoSyncService.wifiOnly = $0 }
                    ))
                    Toggle("Only While Charging", isOn: Binding(
                        get: { photoSyncService.whileChargingOnly },
                        set: { photoSyncService.whileChargingOnly = $0 }
                    ))
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(photoSyncService.status.displayText)
                            .foregroundStyle(.secondary)
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
                    Text("Live Photos back up as still images only. Turning this off leaves already-uploaded photos in Drive.")
                }

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
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PhotoSyncSettingsView(photoSyncService: PhotoSyncService())
    }
}
