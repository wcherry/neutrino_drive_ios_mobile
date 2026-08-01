import SwiftUI
import LocalAuthentication

/// Full-screen overlay presented whenever `BiometricAuthService.shouldPresentOverlay` is true.
///
/// Two distinct jobs, which is why the body branches on `isLocked`:
///
/// 1. **Locked** — block access and offer authentication.
/// 2. **Obscured only** — the app is merely inactive (the app-switcher snapshot is being
///    taken). No buttons, no error copy; just an opaque surface so file names and thumbnails
///    never reach the switcher.
///
/// The background is fully opaque `Color(.systemBackground)` rather than a blur: a blur of a
/// file list is still a recognisable file list, and the switcher screenshot is exactly where
/// that matters.
struct LockScreenView: View {

    @ObservedObject var biometricService: BiometricAuthService

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: iconName)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Neutrino Drive")
                    .font(.title2.weight(.semibold))

                if biometricService.isLocked {
                    Text("Locked")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let error = biometricService.lastError {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    Button {
                        Task { await biometricService.unlock() }
                    } label: {
                        if biometricService.isAuthenticating {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Unlock with \(biometricService.biometryName)")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(biometricService.isAuthenticating)
                    .padding(.horizontal, 48)
                    .padding(.top, 8)
                }
            }
        }
        .transition(.opacity)
        // Only auto-prompt when actually locked. Prompting while merely obscured would fire a
        // Face ID sheet every time the user swipes up to the app switcher.
        .task(id: biometricService.isLocked) {
            if biometricService.isLocked && biometricService.lastError == nil {
                await biometricService.unlock()
            }
        }
    }

    private var iconName: String {
        switch biometricService.biometryType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        default:       return "lock.fill"
        }
    }
}

#Preview {
    LockScreenView(biometricService: BiometricAuthService())
}
