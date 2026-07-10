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
    /// 좋아요·코스 따라가기 알림 탭 → 해당 코스 상세
    @Published var pendingCourseId: String? = nil
    /// Vlog 완성 알림 탭 → 완성본 재생
    @Published var pendingVlogURL: URL? = nil
    /// 주간 리포트 알림 탭 → 프로필(여행 통계)
    @Published var shouldOpenProfile: Bool = false

    // 현재 유저가 보고 있는 채팅방 (roomId + memberUserId)
    var activeChatRoom: PendingChatRoom? = nil
    // 본인이 보낸 알림 클라이언트 측 차단용
    var currentUserId: String? = nil

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
            // 본인이 발생시킨 알림은 표시 안 함
            if let myId = self.currentUserId, senderUserId == myId {
                completionHandler([])
                return
            }

            // 그룹 단톡 알림: 같은 방을 보고 있으면(멤버 무관) 배너 억제
            if type == "chat" {
                if let active = self.activeChatRoom, active.roomId == roomId {
                    completionHandler([])
                } else {
                    completionHandler([.banner, .sound])
                }
                return
            }

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
            guard let type = userInfo["type"] as? String else { return }

            // 방(roomId)과 무관한 알림 — 그동안 탭해도 앱만 열리고 아무 데도 가지 않았다.
            switch type {
            case "course_liked", "course_followed":
                if let courseId = userInfo["courseId"] as? String, !courseId.isEmpty {
                    self.pendingCourseId = courseId
                }
                return
            case "vlog_done":
                if let urlString = userInfo["url"] as? String, let url = URL(string: urlString) {
                    self.pendingVlogURL = url
                }
                return
            case "weekly_report":
                self.shouldOpenProfile = true
                return
            default:
                break
            }

            // 이하 그룹/채팅 알림 — roomId로 열 화면을 정한다.
            guard let roomId = userInfo["roomId"] as? String, !roomId.isEmpty,
                  let senderUserId = userInfo["senderUserId"] as? String else { return }

            switch type {
            case "chat":
                // 그룹 단톡 메시지 알림 → 해당 방 단톡 열기 (멤버 라우팅 불필요)
                self.pendingChatRoom = PendingChatRoom(roomId: roomId, targetUserId: senderUserId)
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
