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
                    notificationManager.currentUserId = user?.uid
                    guard let uid = user?.uid else {
                        ProManager.shared.logOut()
                        return
                    }
                    ProManager.shared.logIn(userId: uid)
                    Task {
                        await FCMService.shared.saveFCMToken(userId: uid)
                        await PushService.shared.registerDeviceToken(userId: uid)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FCMTokenRefreshed"))) { _ in
                    guard let uid = authService.currentUser?.uid else { return }
                    Task {
                        await FCMService.shared.saveFCMToken(userId: uid)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    UNUserNotificationCenter.current().setBadgeCount(0)
                }
        }
    }
}

extension Notification.Name {
    static let appOpenedWithURL = Notification.Name("appOpenedWithURL")
}

// MARK: - AppDelegate for FCM & Push
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            if granted {
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
    }
}
