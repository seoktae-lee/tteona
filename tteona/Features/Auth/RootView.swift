import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authService: AuthService

    var body: some View {
        Group {
            if authService.isLoggedIn {
                MainView()
                    .environmentObject(CourseService())
            } else {
                AuthView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: authService.isLoggedIn)
    }
}
