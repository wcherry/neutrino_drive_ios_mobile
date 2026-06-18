import SwiftUI

// MARK: - CreateFolderSheet

/// Sheet for creating a new folder inside a given parent directory.
struct CreateFolderSheet: View {

    // MARK: - Parameters

    @Binding var isPresented: Bool
    let parentID: String?
    let onConfirm: (String) -> Void

    // MARK: - State

    @State private var name: String = ""

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name", text: $name)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onConfirm(name.trimmingCharacters(in: .whitespaces))
                        isPresented = false
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    CreateFolderSheet(isPresented: .constant(true), parentID: nil) { name in
        print("Create folder: \(name)")
    }
}
