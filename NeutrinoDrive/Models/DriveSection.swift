import Foundation

// MARK: - DriveSection

/// Represents the top-level sections available in the file browser.
enum DriveSection: String, CaseIterable, Identifiable {
    case myDrive = "My Drive"
    case shared  = "Shared"
    case recents = "Recents"
    case trash   = "Trash"

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Icon

    /// SF Symbol name representing this section in the sidebar.
    var iconName: String {
        switch self {
        case .myDrive: return "folder"
        case .shared:  return "person.2"
        case .recents: return "clock"
        case .trash:   return "trash"
        }
    }
}
