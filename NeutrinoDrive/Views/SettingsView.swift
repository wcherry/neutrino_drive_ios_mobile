import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var photoSyncService: PhotoSyncService

    @State private var hasKeys = KeyImportService.hasStoredKeys()
    @State private var showKeyImport = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Text("Settings")
                        .font(.largeTitle)
                        .foregroundStyle(Color(.secondaryLabel))
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .padding(.vertical, 32)
            }

            Section("Encryption Key") {
                if hasKeys {
                    Label("Encryption Key: Imported \u{2713}", systemImage: "key.fill")
                        .foregroundStyle(.primary)

                    Button(role: .destructive) {
                        showRemoveConfirmation = true
                    } label: {
                        Text("Remove Keys")
                    }
                    .alert("Remove Encryption Keys?", isPresented: $showRemoveConfirmation) {
                        Button("Remove", role: .destructive) {
                            KeyImportService.removeKeys()
                            hasKeys = false
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will delete your stored encryption keys. You will need to re-import them to access encrypted files.")
                    }
                } else {
                    Button {
                        showKeyImport = true
                    } label: {
                        Label("Import Encryption Key", systemImage: "key")
                    }
                    .sheet(isPresented: $showKeyImport) {
                        hasKeys = KeyImportService.hasStoredKeys()
                    } content: {
                        KeyImportView(isPresented: $showKeyImport)
                    }
                }
            }

            if FeatureFlags.photoAutoSync {
                Section("Photo Sync") {
                    NavigationLink {
                        PhotoSyncSettingsView(photoSyncService: photoSyncService)
                    } label: {
                        HStack {
                            Label("Back Up My Photos", systemImage: "photo.badge.arrow.down")
                            Spacer()
                            Text(photoSyncSummary)
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    authService.logout()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Sign Out")
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }

    private var photoSyncSummary: String {
        guard photoSyncService.isEnabled else { return "Off" }
        return photoSyncService.pendingCount > 0
            ? "On \u{00B7} \(photoSyncService.pendingCount) waiting"
            : "On"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AuthService())
            .environmentObject(PhotoSyncService())
    }
}
