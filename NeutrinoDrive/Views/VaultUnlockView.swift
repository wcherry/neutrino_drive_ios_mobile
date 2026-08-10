import SwiftUI

// MARK: - VaultUnlockView
//
// Recovers the encryption key from the server-side vault using the encryption
// password (or recovery code) the user set on the web.
//
// This is the replacement for pasting a key bundle in by hand: same account,
// same secret, no file transfer between devices. `KeyImportView` stays available
// for the manual path, which still matters for accounts created before the
// vault existed.

struct VaultUnlockView: View {
    @Binding var isPresented: Bool

    /// Called after the key lands in the Keychain, so the caller can refresh
    /// anything that was blocked on it.
    var onUnlocked: (() -> Void)?

    @State private var secret = ""
    @State private var useRecoveryCode = false
    @State private var isWorking = false
    @State private var errorMessage = ""
    @State private var showSuccess = false

    @EnvironmentObject private var authService: AuthService

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.open.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                Text("Unlock Your Files")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(useRecoveryCode
                     ? "Enter the recovery code you saved when you set up encryption."
                     : "Enter your encryption password. This is the one you chose to protect your key — not your sign-in password.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Group {
                    if useRecoveryCode {
                        TextField("Recovery code", text: $secret)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("Encryption password", text: $secret)
                            .textContentType(.password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 32)
                .disabled(isWorking)
                .onSubmit { Task { await unlock() } }

                if showSuccess {
                    Label("Unlocked — your files are available", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    Task { await unlock() }
                } label: {
                    Group {
                        if isWorking {
                            // Argon2id is deliberately slow — around a second on
                            // older devices — so the wait needs explaining.
                            HStack(spacing: 8) {
                                ProgressView().tint(.white)
                                Text("Unlocking…")
                            }
                        } else {
                            Text("Unlock")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 32)
                .disabled(isWorking || secret.isEmpty)

                Button(useRecoveryCode ? "Use my encryption password instead"
                                       : "Use a recovery code instead") {
                    useRecoveryCode.toggle()
                    secret = ""
                    errorMessage = ""
                }
                .font(.footnote)
                .disabled(isWorking)

                Spacer()
            }
            .navigationTitle("Unlock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .disabled(isWorking)
                }
            }
        }
    }

    // MARK: - Actions

    private func unlock() async {
        guard !secret.isEmpty, !isWorking else { return }
        isWorking = true
        errorMessage = ""
        defer { isWorking = false }

        let service = KeyVaultService(authService: authService)
        do {
            guard let vault = try await service.fetchVault() else {
                errorMessage = KeyVaultError.noVault.localizedDescription
                return
            }
            if useRecoveryCode {
                try await service.unlock(vault: vault, recoveryCode: secret)
            } else {
                try await service.unlock(vault: vault, password: secret)
            }
            secret = ""
            showSuccess = true
            onUnlocked?()
            // Leave the confirmation on screen briefly so the unlock is visibly
            // acknowledged rather than the sheet just vanishing.
            try? await Task.sleep(nanoseconds: 700_000_000)
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
