import Foundation

// MARK: - DriveSection

/// Represents the top-level sections available in the file browser.
enum DriveSection: String, CaseIterable, Identifiable {
    case myDrive = "My Drive"
    case starred = "Starred"
    case shared  = "Shared"
    case recents = "Recents"
    case trash   = "Trash"

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Visible Sections

    /// Sections actually offered in the picker and sidebar.
    ///
    /// `allCases` still contains `.starred` when the feature is off — dropping a case from an
    /// enum at runtime is not possible — so every UI entry point iterates this instead. Keeping
    /// the case present means stored state and switch statements stay exhaustive; only the
    /// presentation is gated.
    static var visibleCases: [DriveSection] {
        allCases.filter { $0 != .starred || FeatureFlags.favorites }
    }

    // MARK: - Icon

    /// SF Symbol name representing this section in the sidebar.
    var iconName: String {
        switch self {
        case .myDrive: return "folder"
        case .starred: return "star"
        case .shared:  return "person.2"
        case .recents: return "clock"
        case .trash:   return "trash"
        }
    }
}
