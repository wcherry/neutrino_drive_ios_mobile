import SwiftUI
import UIKit

/// Settings detail screen for the biometric lock (mvp.md Phase 2 — "Face ID / Touch ID").
struct BiometricSettingsView: View {

    @ObservedObject var biometricService: BiometricAuthService

    @State private var gracePeriod: TimeInterval = BiometricAuthService.defaultGracePeriod
    @State private var showUnavailableAlert = false

    var body: some View {
        Form {
            Section {
                Toggle("Require \(biometricService.biometryName)", isOn: $biometricService.isEnabled)
                    .disabled(!availability.canEnable && !biometricService.isEnabled)
                    .onChange(of: biometricService.isEnabled) { newValue in
                        // The service reverts the toggle itself when biometrics are unusable;
                        // surface the reason rather than letting it silently flip back.
                        if !newValue, biometricService.lastError != nil, !availability.canEnable {
                            showUnavailableAlert = true
                        }
                    }
            } footer: {
                Text(footerText)
            }

            if biometricService.isEnabled {
                Section {
                    Picker("Lock After", selection: $gracePeriod) {
                        ForEach(BiometricAuthService.gracePeriodOptions, id: \.self) { seconds in
                            Text(Self.label(for: seconds)).tag(seconds)
                        }
                    }
                    .onChange(of: gracePeriod) { newValue in
                        biometricService.gracePeriod = newValue
                    }
                } header: {
                    Text("Grace Period")
                } footer: {
                    Text("How long the app may stay in the background before it locks again. Your file list is hidden from the app switcher immediately, regardless of this setting.")
                }
            }

            if !availability.canEnable {
                Section {
                    Label(availability.explanation, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
        .navigationTitle("App Lock")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { gracePeriod = biometricService.gracePeriod }
        .alert("Cannot Enable", isPresented: $showUnavailableAlert) {
            Button("OK") {}
        } message: {
            Text(availability.explanation)
        }
    }

    private var availability: BiometricAvailability { biometricService.availability() }

    private var footerText: String {
        biometricService.isEnabled
            ? "Neutrino Drive will ask for \(biometricService.biometryName) — or your device passcode — before showing your files, and before your encryption keys can be removed."
            : "When on, Neutrino Drive asks for \(biometricService.biometryName) before showing your files. Your device passcode always works as a fallback, so a locked-out sensor never strands you."
    }

    private static func label(for seconds: TimeInterval) -> String {
        switch seconds {
        case 0:   return "Immediately"
        case 60:  return "After 1 minute"
        case 300: return "After 5 minutes"
        case 900: return "After 15 minutes"
        default:  return "After \(Int(seconds))s"
        }
    }
}

#Preview {
    NavigationStack {
        BiometricSettingsView(biometricService: BiometricAuthService())
    }
}
