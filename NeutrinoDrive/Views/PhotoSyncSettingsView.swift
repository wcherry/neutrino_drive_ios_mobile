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
                Text("Photos taken from now on will be backed up. Existing photos in your library are not uploaded.")
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
