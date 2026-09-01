import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - KeyImportView

struct KeyImportView: View {
    @Binding var isPresented: Bool

    @State private var isShowingPicker = false
    @State private var isShowingQRScanner = false
    @State private var showSuccess = false
    @State private var showError = false
    @State private var importedVersion = ""
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "key.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                Text("Import Encryption Key")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Open Neutrino on the web, go to Settings → Encryption and choose "
                     + "\u{201C}Key code for mobile\u{201D}, then scan the code it shows.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if showSuccess {
                    Label("Keys imported successfully (v\(importedVersion))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding()
                }

                // The key code is the live path: the web app no longer exports the JSON key file
                // below, so scanning is how a key reaches this device short of the recovery kit.
                if FeatureFlags.qrKeyScan {
                    Button {
                        isShowingQRScanner = true
                    } label: {
                        Label("Scan Key Code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 32)
                    .sheet(isPresented: $isShowingQRScanner) {
                        KeyQRImportView(isPresented: $isShowingQRScanner)
                    }
                }

                // Kept for accounts that still hold a key file exported by an older web build.
                Button {
                    isShowingPicker = true
                } label: {
                    Label("Import Key File", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.secondary.opacity(0.15))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 32)
                .sheet(isPresented: $isShowingPicker) {
                    DocumentPicker { url in
                        importFrom(url: url)
                    }
                }

                Spacer()
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
            .alert("Import Failed", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Private

    private func importFrom(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)

            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }

            let bundle = try KeyImportService.importKey(from: data)
            KeyImportService.storeKeys(bundle)
            try? FileManager.default.removeItem(at: url)

            importedVersion = bundle.keyVersion
            showSuccess = true

            // The key file holds the account's *retired* keys, sealed to the key just imported.
            // Without this a device joining a rotated account opens everything uploaded since the
            // last rotation and nothing before it. A failure is not fatal — the next launch
            // retries — so the import is not held open waiting for it.
            Task { try? await KeyFileService.shared.restoreArchivedKeys() }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                isPresented = false
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - DocumentPicker

private struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.json]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
