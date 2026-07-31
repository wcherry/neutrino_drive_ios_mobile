import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var driveService: DriveService
    @EnvironmentObject var offlineService: OfflineService
    @EnvironmentObject var photoSyncService: PhotoSyncService

    @StateObject private var quotaService = QuotaService()

    @State private var hasKeys = KeyImportService.hasStoredKeys()
    @State private var showKeyImport = false
    @State private var showRemoveConfirmation = false
    @State private var showClearCacheConfirmation = false

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

            Section("Storage") {
                storageContent
            }

            Section("Cache") {
                Label("Offline Cache: \(formattedCacheSize)", systemImage: "arrow.down.circle")

                Button(role: .destructive) {
                    showClearCacheConfirmation = true
                } label: {
                    Text("Clear Offline Cache")
                }
                .disabled(offlineService.offlineFiles.isEmpty)
                .confirmationDialog(
                    "Clear Offline Cache?",
                    isPresented: $showClearCacheConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear Cache", role: .destructive) {
                        offlineService.removeAll()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will delete all files you've made available offline from this device. They remain in My Drive.")
                }
            }

            Section("Sync") {
                Label(syncStatusText, systemImage: syncStatusIcon)
                    .foregroundStyle(syncStatusColor)
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
        .task {
            quotaService.authService = authService
            await quotaService.refresh()
        }
    }

    // MARK: - Photo Sync

    private var photoSyncSummary: String {
        guard photoSyncService.isEnabled else { return "Off" }
        return photoSyncService.pendingCount > 0
            ? "On \u{00B7} \(photoSyncService.pendingCount) waiting"
            : "On"
    }

    // MARK: - Storage

    @ViewBuilder
    private var storageContent: some View {
        if let quota = quotaService.quota {
            VStack(alignment: .leading, spacing: 8) {
                Text(storageUsageText(quota))
                    .font(.subheadline)
                if let quotaBytes = quota.quotaBytes, quotaBytes > 0 {
                    ProgressView(value: usageRatio(used: quota.usedBytes, total: quotaBytes))
                }
            }
            .padding(.vertical, 4)
        } else if quotaService.isLoading {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else {
            Text("Storage usage unavailable.")
                .foregroundStyle(.secondary)
        }
    }

    private func storageUsageText(_ quota: StorageQuota) -> String {
        let used = Self.byteCountFormatter.string(fromByteCount: quota.usedBytes)
        if let quotaBytes = quota.quotaBytes {
            let total = Self.byteCountFormatter.string(fromByteCount: quotaBytes)
            return "\(used) of \(total) used"
        } else {
            return "\(used) used of Unlimited"
        }
    }

    private func usageRatio(used: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(total)))
    }

    // MARK: - Cache

    private var formattedCacheSize: String {
        Self.byteCountFormatter.string(fromByteCount: offlineService.cacheSizeBytes())
    }

    // MARK: - Sync
    //
    // No real background-sync engine exists in this app — this is a lightweight status row
    // derived from DriveService's existing isLoading/error state, per the plan's scope.

    private var syncStatusText: String {
        if driveService.isLoading { return "Syncing\u{2026}" }
        if let error = driveService.error { return "Sync error: \(error)" }
        return "All changes synced"
    }

    private var syncStatusIcon: String {
        if driveService.isLoading { return "arrow.triangle.2.circlepath" }
        if driveService.error != nil { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private var syncStatusColor: Color {
        driveService.error != nil ? .red : .primary
    }

    // MARK: - Formatting

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter
    }()
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AuthService())
            .environmentObject(DriveService())
            .environmentObject(OfflineService())
            .environmentObject(PhotoSyncService())
    }
}
