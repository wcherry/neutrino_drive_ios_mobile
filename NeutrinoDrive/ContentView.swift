import SwiftUI
import NeutrinoCore
import NeutrinoUI

struct ContentView: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                FilesView()
            }
            .tabItem {
                Label("Files", systemImage: "folder")
            }
            .tag(0)

            NavigationStack {
                RecentsView()
            }
            .tabItem {
                Label("Recents", systemImage: "clock")
            }
            .tag(1)

            NavigationStack {
                OfflineView()
            }
            .tabItem {
                Label("Offline", systemImage: "arrow.down.circle")
            }
            .tag(2)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(3)
        }
        // Drive queues nothing made offline, so the strip promises nothing: it says that what is
        // shown is what this device already has — the Offline tab, and folders already opened.
        .connectivityBanner(isOnline: networkMonitor.isOnline, keepsChangesOffline: false)
    }
}

#Preview {
    ContentView()
        .environmentObject(NetworkMonitor(autoStart: false))
}
