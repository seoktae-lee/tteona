import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var deepLinkHandler: DeepLinkHandler
    @StateObject private var courseService = CourseService()

    var body: some View {
        Group {
            if authService.isInitializing {
                ZStack {
                    Color.tteBackground.ignoresSafeArea()
                    Text("tteona")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundColor(.tteOrange)
                }
            } else if !authService.isLoggedIn || authService.verificationEmailSent {
                AuthView()
            } else if !authService.onboardingComplete {
                OnboardingView()
            } else {
                MainTabView()
                    .environmentObject(courseService)
                    .environmentObject(deepLinkHandler)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: authService.isLoggedIn)
        .animation(.easeInOut(duration: 0.35), value: authService.onboardingComplete)
        .animation(.easeInOut(duration: 0.35), value: authService.isInitializing)
        .onChange(of: authService.isLoggedIn) { _, isLoggedIn in
            if !isLoggedIn {
                courseService.clearUserData()
            }
        }
    }
}
