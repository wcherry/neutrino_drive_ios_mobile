import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService

    var body: some View {
        List {
            Section {
                // Placeholder for future settings rows
                HStack {
                    Spacer()
                    Text("Settings")
                        .font(.largeTitle)
                        .foregroundStyle(Color(.secondaryLabel))
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .padding(.vertical, 32)
            }

            Section {
                Button(role: .destructive) {
                    authService.logout()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Sign Out")
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    // Preview requires a mock AuthService so the environment object is satisfied.
    NavigationStack {
        SettingsView()
            .environmentObject(AuthService())
    }
}
