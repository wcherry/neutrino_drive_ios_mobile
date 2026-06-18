import SwiftUI

// MARK: - FilesView

/// Root view for the Files tab. Adapts its layout for iPhone (compact) and iPad.
struct FilesView: View {

    // MARK: - Environment / State

    @EnvironmentObject var driveService: DriveService
    @State private var selectedSection: DriveSection = .myDrive

    // MARK: - Body

    var body: some View {
        if FeatureFlags.fileBrowser {
            featureFlagEnabledBody
        } else {
            legacyPlaceholder
        }
    }

    // MARK: - Feature-flagged Implementations

    @ViewBuilder
    private var featureFlagEnabledBody: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            ipadBody
        } else {
            iphoneBody
        }
    }

    // MARK: - iPhone Layout

    private var iphoneBody: some View {
        FileBrowserView(section: selectedSection, parentID: nil)
            .environmentObject(driveService)
            .navigationTitle("Files")
            .navigationDestination(for: DriveItem.self) { destination in
                FileBrowserView(section: selectedSection, parentID: destination.id)
                    .environmentObject(driveService)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $selectedSection) {
                        ForEach(DriveSection.allCases) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
            }
    }

    // MARK: - iPad Layout

    private var ipadBody: some View {
        NavigationSplitView {
            List(DriveSection.allCases, id: \.self) { section in
                Label(section.rawValue, systemImage: section.iconName)
                    .tag(section)
                    .listRowBackground(
                        selectedSection == section
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .onTapGesture {
                        selectedSection = section
                    }
            }
            .navigationTitle("Files")
        } detail: {
            FileBrowserView(section: selectedSection, parentID: nil)
                .environmentObject(driveService)
                .navigationDestination(for: DriveItem.self) { destination in
                    FileBrowserView(section: selectedSection, parentID: destination.id)
                        .environmentObject(driveService)
                }
        }
    }

    // MARK: - Legacy Placeholder

    private var legacyPlaceholder: some View {
        VStack {
            Spacer()
            Text("Files")
                .font(.largeTitle)
            Spacer()
        }
        .navigationTitle("Files")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FilesView()
    }
}
