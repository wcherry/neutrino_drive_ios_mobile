import SwiftUI

// MARK: - RenameSheet

/// Sheet for renaming a DriveItem. Pre-fills the current name and disables
/// the Save button when the name is unchanged or empty.
struct RenameSheet: View {

    // MARK: - Parameters

    let item: DriveItem
    let onConfirm: (String) -> Void

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var name: String = ""

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onConfirm(name.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(isSaveDisabled)
                }
            }
            .onAppear {
                name = item.name
            }
        }
    }

    // MARK: - Helpers

    private var isSaveDisabled: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == item.name
    }
}

// MARK: - Preview

#Preview {
    RenameSheet(
        item: DriveItem(
            id: "1",
            name: "Old Name.pdf",
            type: .file,
            parentID: nil,
            size: 1024,
            modifiedAt: Date(),
            isTrashed: false,
            isShared: false,
            mimeType: "application/pdf"
        )
    ) { newName in
        print("Renamed to: \(newName)")
    }
}
