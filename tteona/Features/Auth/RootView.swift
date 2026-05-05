import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authService: AuthService

    var body: some View {
        Group {
            if authService.isInitializing {
                ZStack {
                    Color.tteBackground.ignoresSafeArea()
                    Text("tteona")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundColor(.tteOrange)
                }
            } else if !authService.isLoggedIn {
                AuthView()
            } else if !authService.onboardingComplete {
                OnboardingView()
            } else {
                MainTabView()
                    .environmentObject(CourseService())
            }
        }
        .animation(.easeInOut(duration: 0.35), value: authService.isLoggedIn)
        .animation(.easeInOut(duration: 0.35), value: authService.onboardingComplete)
        .animation(.easeInOut(duration: 0.35), value: authService.isInitializing)
    }
}
