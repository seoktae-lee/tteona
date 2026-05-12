import SwiftUI
import FirebaseAuth

struct RootView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var deepLinkHandler: DeepLinkHandler
    @StateObject private var courseService = CourseService()

    var body: some View {
        let firebaseUser = Auth.auth().currentUser
        let isFirebaseLoggedIn = firebaseUser != nil
        let isFirebaseEmailVerified = firebaseUser?.isEmailVerified ?? false

        Group {
            if authService.isInitializing {
                ZStack {
                    Color.tteBackground.ignoresSafeArea()
                    Text("tteona")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundColor(.tteOrange)
                }
            } else if authService.verificationEmailSent || (isFirebaseLoggedIn && !isFirebaseEmailVerified) {
                AuthView()
            } else if !isFirebaseLoggedIn {
                AuthView()
            } else if authService.currentUser == nil {
                // Firebase에는 로그인되어 있지만 AuthService 상태가 아직 동기화 전인 순간을 안전하게 처리
                ZStack {
                    Color.tteBackground.ignoresSafeArea()
                    Text("tteona")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundColor(.tteOrange)
                }
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
