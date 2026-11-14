import SwiftUI

// MARK: - SmartOfflineSettingsView

/// Settings for automatic offline caching.
///
/// The copy here is deliberately concrete about cost. This feature spends the user's disk and,
/// if they allow it, their cellular data — so the screen states the budget, what is currently
/// held, and which constraints are active, rather than presenting a single opaque toggle.
struct SmartOfflineSettingsView: View {

    @EnvironmentObject private var smartOffline: SmartOfflineSyncService
    @EnvironmentObject private var offlineService: OfflineService

    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        Section("Smart Offline") {
            Toggle("Cache Files Automatically", isOn: Binding(
                get: { smartOffline.isEnabled },
                set: { smartOffline.isEnabled = $0 }
            ))

            Text("Keeps the files you open most often available without a connection. "
                 + "Which files those are is worked out on this device and never sent to the server.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if smartOffline.isEnabled {
                Picker("Storage Limit", selection: Binding(
                    get: { smartOffline.budgetBytes },
                    set: { smartOffline.budgetBytes = $0 }
                )) {
                    ForEach(SmartOfflineSyncService.budgetOptions, id: \.self) { bytes in
                        Text(Self.formatter.string(fromByteCount: bytes)).tag(bytes)
                    }
                }

                Toggle("Wi-Fi Only", isOn: Binding(
                    get: { smartOffline.wifiOnly },
                    set: { smartOffline.wifiOnly = $0 }
                ))

                Toggle("Only While Charging", isOn: Binding(
                    get: { smartOffline.whileChargingOnly },
                    set: { smartOffline.whileChargingOnly = $0 }
                ))

                LabeledContent("Status", value: smartOffline.status.displayText)

                // Recomputed from disk rather than summed from the manifest — see
                // `OfflineService.actualManagedCacheSizeBytes`.
                LabeledContent(
                    "Automatic Cache",
                    value: "\(Self.formatter.string(fromByteCount: offlineService.actualManagedCacheSizeBytes()))"
                         + " of \(Self.formatter.string(fromByteCount: smartOffline.budgetBytes))"
                )

                // Shown separately because pinned files sit *outside* the budget. Folding the
                // two together would make the limit mean something different from what it says.
                LabeledContent(
                    "Files You Pinned",
                    value: Self.formatter.string(fromByteCount: offlineService.pinnedCacheSizeBytes())
                )

                Text("Files you chose with “Make Available Offline” are kept separately and are "
                     + "never removed automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let lastSyncedAt = smartOffline.lastSyncedAt {
                    LabeledContent("Last Checked",
                                   value: lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }
}
