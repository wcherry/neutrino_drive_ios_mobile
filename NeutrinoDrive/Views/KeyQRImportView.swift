import SwiftUI
import VisionKit

// MARK: - KeyQRImportView

struct KeyQRImportView: View {
    @Binding var isPresented: Bool

    @State private var step: ImportStep = .scanning
    @State private var pin: String = ""
    @State private var isDecrypting = false

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .scanning:
                    scanningView
                case .enterPin(let qrString):
                    pinEntryView(qrString: qrString)
                case .success(let keyVersion):
                    successView(keyVersion: keyVersion)
                case .error(let message):
                    errorView(message: message)
                }
            }
            .navigationTitle("Import via QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
    }

    // MARK: - Step Views

    private var scanningView: some View {
        VStack(spacing: 0) {
            if DataScannerViewController.isSupported {
                ZStack(alignment: .bottom) {
                    QRScannerView { qrString in
                        DispatchQueue.main.async {
                            pin = ""
                            step = .enterPin(qrString: qrString)
                        }
                    }
                    .ignoresSafeArea(edges: .top)

                    Text("Point your camera at a Neutrino Drive key QR code.")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 32)
                        .padding(.horizontal, 24)
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("QR scanning not supported on this device.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Use the \"Import Key File\" option instead.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.horizontal, 32)
            }
        }
    }

    private func pinEntryView(qrString: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("Enter your PIN")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter the PIN used to protect this key QR code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .padding(.horizontal, 32)

            if isDecrypting {
                ProgressView()
                    .padding(.top, 8)
            } else {
                Button {
                    decryptAndImport(qrString: qrString)
                } label: {
                    Text("Decrypt & Import")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(pin.isEmpty ? Color.accentColor.opacity(0.4) : Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(pin.isEmpty)
                .padding(.horizontal, 32)
            }

            Spacer()
        }
    }

    private func successView(keyVersion: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Keys imported successfully (v\(keyVersion))")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.red)

            Text("Import Failed")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                pin = ""
                step = .scanning
            } label: {
                Text("Try Again")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Decrypt & Import

    private func decryptAndImport(qrString: String) {
        let capturedPin = pin
        isDecrypting = true

        Task {
            do {
                let keyData = try await Task.detached(priority: .userInitiated) {
                    try KeyQRDecryptService.decrypt(qrString: qrString, pin: capturedPin)
                }.value

                let bundle = try KeyImportService.importKey(from: keyData)
                KeyImportService.storeKeys(bundle)

                await MainActor.run {
                    isDecrypting = false
                    step = .success(keyVersion: bundle.keyVersion)
                }

                try? await Task.sleep(nanoseconds: 1_500_000_000)

                await MainActor.run {
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    isDecrypting = false
                    step = .error(message: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - ImportStep

private enum ImportStep {
    case scanning
    case enterPin(qrString: String)
    case success(keyVersion: String)
    case error(message: String)
}
