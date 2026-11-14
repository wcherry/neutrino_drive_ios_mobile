import SwiftUI

// MARK: - View + Conditional Modifier

extension View {
    /// Applies `transform` only when `condition` holds.
    ///
    /// Used by the drag-and-drop wiring so a disabled `FeatureFlags.dragAndDrop` attaches **no**
    /// `.onDrag`/`.onDrop` modifier at all, rather than attaching one that returns nil. The
    /// distinction matters: a registered drop target still highlights and still intercepts the
    /// gesture, so "attached but inert" would look broken rather than absent.
    ///
    /// Changing the condition changes the view's identity, so this must only be used with
    /// conditions that are constant for a view's lifetime — feature flags and item type here,
    /// never transient state.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool,
                             transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
