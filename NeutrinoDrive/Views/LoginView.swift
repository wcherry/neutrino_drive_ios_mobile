import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authService: AuthService

    @State private var serverHost: String = UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isLoading = false

    private var canSubmit: Bool { !email.isEmpty && !password.isEmpty && !serverHost.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 60)

                // App icon
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(.systemIndigo), Color(.systemBlue)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 96, height: 96)
                        .shadow(color: Color(.systemIndigo).opacity(0.35), radius: 20, x: 0, y: 8)

                    Image(systemName: "externaldrive.fill.badge.wifi")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                }

                Spacer().frame(height: 32)

                Text("Neutrino Drive")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color(.label))

                Spacer().frame(height: 10)

                Text("Secure encrypted file storage")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color(.secondaryLabel))

                Spacer().frame(height: 48)

                // Trust indicators
                VStack(spacing: 16) {
                    TrustRow(icon: "lock.shield.fill",  title: "End-to-end encrypted",        color: Color(.systemGreen))
                    TrustRow(icon: "icloud.fill",       title: "Zero-knowledge cloud storage", color: Color(.systemBlue))
                    TrustRow(icon: "key.fill",          title: "Only you hold your keys",      color: Color(.systemIndigo))
                }
                .padding(.horizontal, 40)

                Spacer().frame(height: 40)

                // Server + credential fields
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Color(.secondaryLabel))
                            .frame(width: 20)
                        TextField("Server (e.g. http://192.168.1.x:8080)", text: $serverHost)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: serverHost) { newValue in
                        UserDefaults.standard.set(newValue, forKey: AuthService.serverHostKey)
                    }

                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    SecureField("Password", text: $password)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 32)

                // Error label
                if let error = authService.loginError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(.systemRed))
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(.systemRed))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .transition(.opacity)
                }

                Spacer().frame(height: 24)

                // Sign-in button
                VStack(spacing: 14) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.1)
                            .tint(Color(.systemIndigo))
                            .frame(height: 52)
                    } else {
                        Button(action: handleSignIn) {
                            HStack(spacing: 10) {
                                Image(systemName: "person.badge.shield.checkmark.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                Text("Sign In")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                LinearGradient(
                                    colors: [Color(.systemIndigo), Color(.systemBlue)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .opacity(canSubmit ? 1 : 0.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Color(.systemIndigo).opacity(canSubmit ? 0.3 : 0), radius: 8, x: 0, y: 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                    }

                    Text("By signing in you agree to our Terms of Service and Privacy Policy.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(.tertiaryLabel))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .animation(.easeInOut(duration: 0.2), value: authService.loginError != nil)
        .onChange(of: authService.isAuthenticated) { _ in isLoading = false }
        .onChange(of: authService.loginError) { _ in if authService.loginError != nil { isLoading = false } }
    }

    private func handleSignIn() {
        isLoading = true
        Task { await authService.login(email: email, password: password) }
    }
}

// MARK: - Supporting Views

private struct TrustRow: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
            }

            Text(title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color(.label))

            Spacer()
        }
    }
}

// MARK: - Previews

#Preview("Default") {
    LoginView()
        .environmentObject(AuthService())
}

#Preview("Error") {
    let service = AuthService()
    service.loginError = "Invalid email or password."
    return LoginView().environmentObject(service)
}
