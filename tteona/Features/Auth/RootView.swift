import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authService: AuthService

    var body: some View {
        Group {
            if !authService.isLoggedIn {
                AuthView()
            } else if !authService.onboardingComplete {
                OnboardingView()
            } else {
                MainView()
                    .environmentObject(CourseService())
            }
        }
        .animation(.easeInOut(duration: 0.35), value: authService.isLoggedIn)
        .animation(.easeInOut(duration: 0.35), value: authService.onboardingComplete)
    }
}
