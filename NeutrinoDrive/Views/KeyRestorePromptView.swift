import SwiftUI
import NeutrinoCrypto
import NeutrinoUI

// MARK: - KeyRestorePromptView
//
// Offered at sign-in when this device holds no encryption key.
//
// It exists so the problem is raised when it can be fixed calmly, rather than at the first file
// the user taps — where it arrives as "No encryption key found" on top of whatever they were
// trying to do. The routes are the same two Settings offers, and deliberately no more:
//
//   recovery kit   the printed backup, typed in (`RecoveryKitImportView`)
//   key code       the PIN-protected QR the web app shows, or an exported key file (`KeyImportView`)
//
// There is no "create a new key" here, for the same reason Settings has none: this account's files
// are sealed to an identity that already exists, and minting a fresh one would orphan every one of
// them. There is also no server-side vault to unlock — the web app creates the key on the device
// and never transmits it.
//
// Dismissible on purpose. Browsing still works without a key, and Settings is where both routes
// live, so a hard gate would lock the user out of their own way back in.

struct KeyRestorePromptView: View {

    @Binding var isPresented: Bool

    /// Called once a key is in the Keychain, so the caller can retry whatever was blocked on it.
    var onImported: () -> Void = {}

    @State private var showRecoveryKit = false
    @State private var showKeyImport = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This device doesn't have your encryption key, so your files can't be "
                         + "opened here yet. Your key was created on another device and never sent "
                         + "to us, so bring it here from your recovery kit or from the web app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Recovery kit") {
                    Button {
                        showRecoveryKit = true
                    } label: {
                        Label("Enter Recovery Kit", systemImage: "doc.text")
                    }
                }

                Section("From the web app") {
                    Button {
                        showKeyImport = true
                    } label: {
                        Label("Scan Key Code", systemImage: "key")
                    }
                }
            }
            .navigationTitle("Restore Your Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // "Not Now" rather than "Cancel": nothing is being abandoned, and Settings ›
                    // Encryption is where this comes back.
                    Button("Not Now") { isPresented = false }
                }
            }
            .sheet(isPresented: $showRecoveryKit) {
                finishIfImported()
            } content: {
                RecoveryKitImportView(isPresented: $showRecoveryKit) {
                    finishIfImported()
                }
            }
            .sheet(isPresented: $showKeyImport) {
                finishIfImported()
            } content: {
                KeyImportView(isPresented: $showKeyImport)
            }
        }
    }

    /// Closes the prompt once a key has actually landed. Checked rather than assumed: both sheets
    /// can be dismissed without importing anything, and closing then would hide the one screen
    /// that explains why the app cannot open files.
    private func finishIfImported() {
        guard KeyImportService.hasStoredKeys() else { return }
        onImported()
        isPresented = false
    }
}
