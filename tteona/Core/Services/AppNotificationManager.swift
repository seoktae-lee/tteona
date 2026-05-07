//
//  AppNotificationManager.swift
//  tteona
//
//  Created by 이석태 on 5/5/26.
//


import Foundation
import UserNotifications
import Combine

@MainActor
class AppNotificationManager: NSObject, ObservableObject {
    static let shared = AppNotificationManager()
    @Published var pendingPlaceName: String? = nil
    @Published var shouldOpenTodaySession: Bool = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
}

extension AppNotificationManager: UNUserNotificationCenterDelegate {
    // 앱이 포그라운드일 때도 알림 표시
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // 알림 탭했을 때
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let action = userInfo["action"] as? String {
            Task { @MainActor in
                switch action {
                case "openCamera":
                    if let placeName = userInfo["placeName"] as? String {
                        self.pendingPlaceName = placeName
                    }
                case "openTodaySession":
                    self.shouldOpenTodaySession = true
                default:
                    break
                }
            }
        }
        completionHandler()
    }
}
