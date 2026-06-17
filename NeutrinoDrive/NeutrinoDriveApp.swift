import SwiftUI

@main
struct NeutrinoDriveApp: App {
    @StateObject private var authService = AuthService()

    var body: some Scene {
        WindowGroup {
            if authService.isAuthenticated {
                ContentView()
                    .environmentObject(authService)
            } else {
                LoginView()
                    .environmentObject(authService)
            }
        }
    }
}
