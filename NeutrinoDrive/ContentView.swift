import SwiftUI

struct ContentView: View {
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
    }
}

#Preview {
    ContentView()
}
