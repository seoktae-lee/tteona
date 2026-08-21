import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var deepLinkHandler: DeepLinkHandler
    @EnvironmentObject private var notificationManager: AppNotificationManager
    @StateObject private var courseService = CourseService()
    @StateObject private var network = NetworkMonitor.shared
    /// 게스트 약관 동의 여부 — UserDefaults 직접 읽기로는 화면이 갱신되지 않아 상태로 들고 있는다
    @State private var guestTermsAgreed = GuestTermsConsent.isAgreed

    var body: some View {
        content
            .overlay(alignment: .top) {
                if !network.isOnline {
                    OfflineBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: network.isOnline)
    }

    private var content: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-previewPaywall") {
                ProPaywallView()
            } else if ProcessInfo.processInfo.arguments.contains("-previewOnboarding") {
                OnboardingView()
            } else if ProcessInfo.processInfo.arguments.contains("-previewNavGuide")
                        || ProcessInfo.processInfo.arguments.contains("-previewProfileTab")
                        || ProcessInfo.processInfo.arguments.contains("-previewDiscoverTab") {
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
            // 로그인은 더 이상 앱을 여는 조건이 아니다.
            // 촬영·브이로그 합성·앨범 저장은 전부 기기 안에서 끝나므로 게스트로 완주할 수 있고,
            // 계정은 그룹·코스·발자취처럼 서버가 필요한 순간에만 요구한다.
            if authService.isInitializing {
                SplashView()
            } else if authService.verificationEmailSent {
                AuthView()   // 이메일 인증 대기 중에는 그 화면을 지킨다
            } else if authService.isLoggedIn && !authService.onboardingComplete {
                OnboardingView()
            } else if !authService.isLoggedIn && !guestTermsAgreed {
                // 계정 온보딩은 가입한 사람만 거치는데 그 안에 약관 동의가 들어 있다.
                // 게스트도 촬영·브이로그·앨범 저장까지 서비스를 온전히 쓰므로 동의를 받는다.
                // 넘어갈 수 없는 화면이어야 해서 내비 가이드의 한 단계로 넣지 않았다.
                GuestTermsGate {
                    GuestTermsConsent.record()
                    withAnimation(.easeInOut(duration: 0.3)) { guestTermsAgreed = true }
                }
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

// MARK: - 오프라인 배너 (상단)
private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.tte(13, .semibold))
            Text(L("network.offline"))
                .font(.tte(13, .medium))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.top, safeTop + 6)
        .padding(.bottom, 8)
        .background(Color.tteDarkGray.opacity(0.92))
        .ignoresSafeArea(edges: .top)
    }

    private var safeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }
}
