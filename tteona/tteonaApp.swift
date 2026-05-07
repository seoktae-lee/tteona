//
//  tteonaApp.swift
//  tteona
//
//  Created by 이석태 on 5/5/26.
//

import SwiftUI
import FirebaseCore
import FirebaseMessaging
import KakaoSDKCommon
import KakaoSDKAuth
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
                .onChange(of: authService.currentUser) { _, user in
                    guard let uid = user?.uid else { return }
                    Task {
                        await FCMService.shared.saveFCMToken(userId: uid)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FCMTokenRefreshed"))) { _ in
                    guard let uid = authService.currentUser?.uid else { return }
                    Task {
                        await FCMService.shared.saveFCMToken(userId: uid)
                    }
                }
        }
    }
}

// MARK: - AppDelegate for FCM & Push
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            print("[FCM] push permission granted: \(granted)")
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        Messaging.messaging().delegate = FCMService.shared
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
