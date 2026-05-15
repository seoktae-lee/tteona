//
//  AppNotificationManager.swift
//  tteona
//
//  Created by 이석태 on 5/5/26.
//


import Foundation
import UserNotifications
import Combine

struct PendingChatRoom: Equatable {
    let roomId: String
    let targetUserId: String  // 열어야 할 피드 주인 userId
}

@MainActor
class AppNotificationManager: NSObject, ObservableObject {
    static let shared = AppNotificationManager()
    @Published var pendingPlaceName: String? = nil
    @Published var shouldOpenTodaySession: Bool = false
    @Published var pendingChatRoom: PendingChatRoom? = nil

    // 현재 유저가 보고 있는 채팅방 (roomId + memberUserId)
    var activeChatRoom: PendingChatRoom? = nil

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
}

extension AppNotificationManager: UNUserNotificationCenterDelegate {
    // 앱이 포그라운드일 때 알림 표시 여부 결정
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        guard let type = userInfo["type"] as? String,
              let roomId = userInfo["roomId"] as? String,
              let senderUserId = userInfo["senderUserId"] as? String else {
            completionHandler([.banner, .sound])
            return
        }

        Task { @MainActor in
            let targetUserId: String
            if type == "feed_comment" {
                targetUserId = (userInfo["targetUserId"] as? String) ?? senderUserId
            } else {
                targetUserId = senderUserId
            }

            // 현재 해당 피드창을 보고 있으면 알림 표시 안 함
            if let active = self.activeChatRoom,
               active.roomId == roomId,
               active.targetUserId == targetUserId {
                completionHandler([])
            } else {
                completionHandler([.banner, .sound])
            }
        }
    }

    // 알림 탭했을 때
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            if let action = userInfo["action"] as? String {
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
            // FCM data payload
            guard let type = userInfo["type"] as? String,
                  let roomId = userInfo["roomId"] as? String, !roomId.isEmpty,
                  let senderUserId = userInfo["senderUserId"] as? String else { return }

            switch type {
            case "feed_comment":
                // 댓글 알림 → 내(피드 작성자) 피드창 열기
                let openUserId = (userInfo["targetUserId"] as? String) ?? senderUserId
                self.pendingChatRoom = PendingChatRoom(roomId: roomId, targetUserId: openUserId)
            case "free_trip_start", "free_trip_end", "course_trip_start", "video_recorded":
                // 영상 촬영/여행 알림 → 촬영한 사람(sender) 피드창 열기
                self.pendingChatRoom = PendingChatRoom(roomId: roomId, targetUserId: senderUserId)
            default:
                break
            }
        }
        completionHandler()
    }
}
