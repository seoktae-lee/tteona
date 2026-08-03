import SwiftUI
import FirebaseCore
import FirebaseMessaging
import KakaoSDKCommon
import KakaoSDKAuth
import GoogleMaps
import UserNotifications

@main
struct TteonaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var authService = AuthService()
    @StateObject private var notificationManager = AppNotificationManager.shared
    @StateObject private var deepLinkHandler = DeepLinkHandler()
    @StateObject private var languageManager = LanguageManager.shared

    init() {
        FirebaseApp.configure()
        KakaoSDK.initSDK(appKey: "49d0d57217d4659334d500aa7a763ee4")
        // 구글맵 SDK — Info.plist의 기존 Google 키 재사용 (번들ID 제한 걸려 있음)
        if let mapsKey = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String {
            GMSServices.provideAPIKey(mapsKey)
        }
        ProManager.shared.configure(userId: nil)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // 언어 변경 시 id가 바뀌면서 뷰 트리 전체가 재구성돼 새 언어가 즉시 반영됨
                .id(languageManager.language)
                .environment(\.locale, languageManager.locale)
                .environmentObject(languageManager)
                .environmentObject(authService)
                .environmentObject(notificationManager)
                .environmentObject(deepLinkHandler)
                .onOpenURL { url in
                    if AuthApi.isKakaoTalkLoginUrl(url) {
                        AuthController.handleOpenUrl(url: url)
                        return
                    }
                    deepLinkHandler.handle(url: url)
                }
                .onReceive(NotificationCenter.default.publisher(for: .appOpenedWithURL)) { notification in
                    guard let url = notification.object as? URL else { return }
                    deepLinkHandler.handle(url: url)
                }
                .onChange(of: authService.currentUser) { _, user in
                    // 게스트(익명)는 계정이 아니다 — 결제 신원도 푸시 등록도 붙이지 않는다.
                    // RevenueCat에 익명 uid를 물리면 그 상태로 결제가 이뤄지고,
                    // 익명 구매는 기기를 바꾸면 복원되지 않는다.
                    notificationManager.currentUserId = authService.isLoggedIn ? user?.uid : nil
                    guard authService.isLoggedIn, let uid = user?.uid else {
                        ProManager.shared.logOut()
                        return
                    }
                    ProManager.shared.logIn(userId: uid)
                    let lang = LanguageManager.shared.language.rawValue
                    Task {
                        await FCMService.shared.saveFCMToken(userId: uid, lang: lang)
                        await PushService.shared.registerDeviceToken(userId: uid, lang: lang)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FCMTokenRefreshed"))) { _ in
                    guard authService.isLoggedIn, let uid = authService.currentUser?.uid else { return }
                    let lang = LanguageManager.shared.language.rawValue
                    Task {
                        await FCMService.shared.saveFCMToken(userId: uid, lang: lang)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .apnsTokenReceived)) { _ in
                    // 로그인 시점에 APNs 토큰이 아직 없어 등록을 건너뛴 경우를 보완 —
                    // 토큰 도착 즉시 WAS에 등록 (좋아요·Vlog 완성·채팅 푸시가 여기에 의존)
                    guard authService.isLoggedIn, let uid = authService.currentUser?.uid else { return }
                    let lang = LanguageManager.shared.language.rawValue
                    Task {
                        await PushService.shared.registerDeviceToken(userId: uid, lang: lang)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in
                    // 앱 언어를 바꾸면 서버에 등록된 lang도 갱신해야 다음 알림부터 새 언어로 온다.
                    guard authService.isLoggedIn, let uid = authService.currentUser?.uid else { return }
                    let lang = LanguageManager.shared.language.rawValue
                    Task {
                        await PushService.shared.registerDeviceToken(userId: uid, lang: lang)
                        await FCMService.shared.saveFCMToken(userId: uid, lang: lang)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    UNUserNotificationCenter.current().setBadgeCount(0)
                    // 서버 쪽 카운터도 함께 비운다 — 안 그러면 다음 알림이 낡은 숫자를 이어받는다.
                    guard authService.isLoggedIn, let uid = authService.currentUser?.uid else { return }
                    Task { await FCMService.shared.clearBadge(userId: uid) }
                }
        }
    }
}

extension Notification.Name {
    static let appOpenedWithURL = Notification.Name("appOpenedWithURL")
    static let apnsTokenReceived = Notification.Name("apnsTokenReceived")
}

// MARK: - AppDelegate for FCM & Push
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 권한 요청은 온보딩 권한 단계에서 맥락과 함께 진행 —
        // 여기서는 이미 허용된 경우에만 원격 알림 재등록
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        Messaging.messaging().delegate = FCMService.shared
        return true
    }

    /// 카카오톡 로그인 후 앱으로 돌아올 때 URL이 여기로 올 수 있음(SwiftUI `onOpenURL`만으로는 누락되는 경우가 있음).
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if AuthApi.isKakaoTalkLoginUrl(url) {
            return AuthController.handleOpenUrl(url: url)
        }
        NotificationCenter.default.post(name: .appOpenedWithURL, object: url)
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(tokenString, forKey: "apnsDeviceToken")
        NotificationCenter.default.post(name: .apnsTokenReceived, object: nil)
    }

    /// 등록 실패는 그동안 조용히 삼켜졌다 — 토큰이 없으면 원격 푸시가 전부 사라지므로 남긴다.
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        dlog("[APNs] 원격 알림 등록 실패:", error.localizedDescription)
    }
}
