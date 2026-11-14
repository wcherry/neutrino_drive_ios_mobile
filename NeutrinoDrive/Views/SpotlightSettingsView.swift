import SwiftUI

// MARK: - SpotlightSettingsView

/// The opt-in for CoreSpotlight indexing.
///
/// The copy here is the feature, not decoration. This is the screen where a user decides whether
/// to move their filenames outside the end-to-end-encrypted boundary, and it has to be accurate
/// about two things that are easy to soften:
///
/// 1. Spotlight's index is **not** end-to-end encrypted. It is a system database, readable by
///    the system and included in device backups.
/// 2. Turning this off does **not** hide filenames from the system, because the Files App
///    integration surfaces them regardless. Implying otherwise would make this control worse
///    than useless — a privacy switch that is trusted and does not do what it says.
struct SpotlightSettingsView: View {

    @ObservedObject var spotlightService: SpotlightIndexService

    var body: some View {
        Form {
            Section {
                Toggle("Index File Names", isOn: $spotlightService.isEnabled)
            } footer: {
                Text("""
                     Lets you find your files by name from the iOS home screen and system search.

                     Off by default. Neutrino Drive is end-to-end encrypted, but Spotlight's \
                     search index is not — it is stored by the system and included in device \
                     backups. A file name can reveal as much as its contents.
                     """)
            }

            Section("What Gets Indexed") {
                Label("File and folder names", systemImage: "textformat")
                Label("File type and date modified", systemImage: "calendar")
            }

            Section {
                Label("File contents", systemImage: "xmark.circle")
                Label("Decrypted text or previews", systemImage: "xmark.circle")
                Label("Thumbnails", systemImage: "xmark.circle")
            } header: {
                Text("Never Indexed")
            } footer: {
                Text("""
                     Your file contents are never written to the search index, whether this \
                     setting is on or off.
                     """)
            }

            Section {
                Label {
                    Text("""
                         This setting controls Neutrino Drive's own indexing only. Files you \
                         browse in the iOS Files app are visible to the system whether or not \
                         this is turned on.
                         """)
                    .font(.footnote)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if spotlightService.isEnabled {
                Section {
                    Button("Remove Indexed Names", role: .destructive) {
                        spotlightService.deindexAll()
                    }
                } footer: {
                    Text("Removes everything Neutrino Drive has added to the search index. Turning the setting off does this automatically.")
                }
            }
        }
        .navigationTitle("Spotlight Indexing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
