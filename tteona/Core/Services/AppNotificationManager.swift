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
        if let placeName = userInfo["placeName"] as? String,
           let action = userInfo["action"] as? String,
           action == "openCamera" {
            Task { @MainActor in
                self.pendingPlaceName = placeName
            }
        }
        completionHandler()
    }
}
