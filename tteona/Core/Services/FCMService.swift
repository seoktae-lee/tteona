import Foundation
import FirebaseFirestore
import FirebaseMessaging
import UIKit

@MainActor
class FCMService: NSObject {
    static let shared = FCMService()

    private let db = Firestore.firestore()

    // MARK: - FCM 토큰 저장
    /// `lang`은 Cloud Functions가 그룹 알림 문구를 어느 언어로 쓸지 정하는 값이다.
    func saveFCMToken(userId: String, lang: String) async {
        Messaging.messaging().token { token, error in
            guard let token, error == nil else {
                #if DEBUG
                dlog("[FCM] token fetch failed: \(error?.localizedDescription ?? "")")
                #endif
                return
            }
            Task {
                // 민감정보는 userPrivate로 분리 저장 (본인만 접근)
                try? await Firestore.firestore()
                    .collection("userPrivate").document(userId)
                    .setData(["fcmToken": token, "lang": lang], merge: true)

                // 과거에 users 문서에 저장된 fcmToken이 남아있다면 제거
                try? await Firestore.firestore()
                    .collection("users").document(userId)
                    .updateData(["fcmToken": FieldValue.delete()])

                #if DEBUG
                dlog("[FCM] token saved: \(token.prefix(20))...")
                #endif
            }
        }
    }

    // MARK: - 배지 초기화
    /// 앱이 포그라운드로 올라오면 안 읽은 알림 수를 0으로 되돌린다.
    /// 서버(WAS·Cloud Functions)는 이 값을 올려 가며 배지 숫자를 만들므로,
    /// 여기서 지우지 않으면 앱을 열어도 배지가 계속 남는다.
    func clearBadge(userId: String) async {
        try? await db.collection("userPrivate").document(userId)
            .setData(["badgeCount": 0], merge: true)
    }

    // MARK: - 그룹 멤버에게 알림 요청 작성
    func requestGroupNotification(
        type: GroupNotificationType,
        senderUserId: String,
        senderNickname: String,
        roomIds: [String],
        courseName: String? = nil,
        placeName: String? = nil
    ) {
        guard !roomIds.isEmpty else { return }
        let data: [String: Any] = [
            "type": type.rawValue,
            "senderUserId": senderUserId,
            "senderNickname": senderNickname,
            "roomIds": roomIds,
            "courseName": courseName as Any,
            "placeName": placeName as Any,
            "createdAt": FieldValue.serverTimestamp(),
            "processed": false
        ]
        db.collection("fcmRequests").document(UUID().uuidString).setData(data)
        #if DEBUG
        dlog("[FCM] notification request written: \(type.rawValue)")
        #endif
    }

    // MARK: - 댓글 알림 (피드 작성자에게만)
    func requestCommentNotification(
        senderUserId: String,
        senderNickname: String,
        feedAuthorUserId: String,
        roomId: String,
        commentText: String
    ) {
        let data: [String: Any] = [
            "type": GroupNotificationType.feedComment.rawValue,
            "senderUserId": senderUserId,
            "senderNickname": senderNickname,
            "targetUserId": feedAuthorUserId,
            "roomIds": [roomId],
            "commentText": commentText,
            "createdAt": FieldValue.serverTimestamp(),
            "processed": false
        ]
        db.collection("fcmRequests").document(UUID().uuidString).setData(data)
        #if DEBUG
        dlog("[FCM] comment notification request written")
        #endif
    }
}

// MARK: - Messaging Delegate
extension FCMService: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        #if DEBUG
        dlog("[FCM] token refreshed")
        #endif
        NotificationCenter.default.post(
            name: Notification.Name("FCMTokenRefreshed"),
            object: nil,
            userInfo: ["token": token]
        )
    }
}

enum GroupNotificationType: String {
    case freeTripStart = "free_trip_start"       // 나의 오늘 시작
    case freeTripEnd = "free_trip_end"           // 나의 오늘 종료
    case courseTripStart = "course_trip_start"   // 코스 여행 시작
    case videoRecorded = "video_recorded"        // 장소 영상 촬영
    case feedComment = "feed_comment"            // 피드 댓글
}
