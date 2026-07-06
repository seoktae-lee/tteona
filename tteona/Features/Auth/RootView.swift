import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var deepLinkHandler: DeepLinkHandler
    @EnvironmentObject private var notificationManager: AppNotificationManager
    @StateObject private var courseService = CourseService()

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-previewOnboarding") {
                OnboardingView()
            } else if ProcessInfo.processInfo.arguments.contains("-previewNavGuide") {
                MainTabView()
                    .environmentObject(courseService)
                    .environmentObject(deepLinkHandler)
                    .environmentObject(notificationManager)
            } else {
                rootContent
            }
            #else
            rootContent
            #endif
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

    @ViewBuilder
    private var rootContent: some View {
            if authService.isInitializing {
                SplashView()
            } else if !authService.isLoggedIn || authService.verificationEmailSent {
                AuthView()
            } else if !authService.onboardingComplete {
                OnboardingView()
            } else {
                MainTabView()
                    .environmentObject(courseService)
                    .environmentObject(deepLinkHandler)
                    .environmentObject(notificationManager)
            }
    }
}

// MARK: - 앱 진입 스플래시 — 주황 일렁임 배경 위 로고가 부드럽게 떠오름
private struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            TteonaSplashBackground()
            TteonaWordmarkLogo(height: 46)
                .scaleEffect(appeared ? 1.0 : 0.9)
                .opacity(appeared ? 1.0 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { appeared = true }
        }
    }
}
