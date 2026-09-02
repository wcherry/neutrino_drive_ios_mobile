import SwiftUI
import NeutrinoCrypto

// MARK: - RecoveryKitImportView
//
// Restore the account's identity from the printed recovery kit.
//
// This replaces the "unlock with your encryption password" sheet. There is no
// server-side key vault any more — the web app creates the key on the device,
// wraps it there and never transmits it — so the kit and the mobile key code are
// the only two ways an identity reaches a phone. See `RecoveryKit`.
//
// There is deliberately no "create a key" path here: this account's files are
// sealed to an identity that already exists, and minting a second one would
// produce a device that encrypts happily and can read nothing it did not write.

struct RecoveryKitImportView: View {
    @Binding var isPresented: Bool

    /// Called after a successful restore so the presenting screen can re-read its key state.
    var onImported: () -> Void = {}

    @State private var kitText = ""
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var successNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Type or paste the recovery kit you printed when you set up encryption. "
                         + "Spaces, dashes and capitalisation do not matter.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                Section("Recovery Kit") {
                    TextEditor(text: $kitText)
                        .frame(minHeight: 140)
                        .font(.system(.body, design: .monospaced))
                        // No autocapitalisation modifier: `RecoveryKit.normalize` upper-cases and
                        // folds the ambiguous characters anyway, so the keyboard is left alone.
                        .autocorrectionDisabled()
                        .disabled(isRestoring)
                }

                if let successNote {
                    Section {
                        Label(successNote, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        restore()
                    } label: {
                        if isRestoring {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Restore Key")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isRestoring || kitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Recovery Kit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }

    // MARK: - Private

    private func restore() {
        errorMessage = nil
        successNote = nil
        isRestoring = true

        let text = kitText
        Task {
            do {
                let contents = try RecoveryKit.importKit(text)
                guard RecoveryKit.install(contents) else {
                    throw RecoveryKitError.couldNotStore
                }

                // The kit already carries every version, so this is a top-up rather than the
                // repair it is on the QR path: it picks up anything retired on another device
                // since the kit was printed. A failure is not fatal — the next launch retries.
                try? await KeyFileService.shared.restoreArchivedKeys()

                let retired = contents.retired.count
                let earlier = retired == 0
                    ? ""
                    : " and \(retired) earlier \(retired == 1 ? "key" : "keys")"
                isRestoring = false
                successNote = "Key v\(contents.activeVersion) restored\(earlier)."
                onImported()

                try? await Task.sleep(nanoseconds: 1_500_000_000)
                isPresented = false
            } catch {
                isRestoring = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
