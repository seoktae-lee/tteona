import Foundation
import FirebaseFirestore
import FirebaseMessaging
import UIKit

@MainActor
class FCMService: NSObject {
    static let shared = FCMService()

    private let db = Firestore.firestore()

    // MARK: - FCM 토큰 저장
    func saveFCMToken(userId: String) async {
        Messaging.messaging().token { token, error in
            guard let token, error == nil else {
                print("[FCM] token fetch failed: \(error?.localizedDescription ?? "")")
                return
            }
            Task {
                try? await Firestore.firestore()
                    .collection("users").document(userId)
                    .setData(["fcmToken": token], merge: true)
                print("[FCM] token saved: \(token.prefix(20))...")
            }
        }
    }

    // MARK: - 그룹 멤버에게 알림 요청 작성
    func requestGroupNotification(
        type: GroupNotificationType,
        senderUserId: String,
        senderNickname: String,
        roomIds: [String],
        courseName: String? = nil
    ) {
        guard !roomIds.isEmpty else { return }
        let data: [String: Any] = [
            "type": type.rawValue,
            "senderUserId": senderUserId,
            "senderNickname": senderNickname,
            "roomIds": roomIds,
            "courseName": courseName as Any,
            "createdAt": FieldValue.serverTimestamp(),
            "processed": false
        ]
        db.collection("fcmRequests").document(UUID().uuidString).setData(data)
        print("[FCM] notification request written: \(type.rawValue)")
    }

    // MARK: - 댓글 알림 (피드 작성자에게만)
    func requestCommentNotification(
        senderUserId: String,
        senderNickname: String,
        feedAuthorUserId: String,
        roomId: String,
        commentText: String
    ) {
        guard senderUserId != feedAuthorUserId else { return }
        let data: [String: Any] = [
            "type": GroupNotificationType.feedComment.rawValue,
            "senderUserId": senderUserId,
            "senderNickname": senderNickname,
            "targetUserId": feedAuthorUserId,
            "roomId": roomId,
            "commentText": commentText,
            "createdAt": FieldValue.serverTimestamp(),
            "processed": false
        ]
        db.collection("fcmRequests").document(UUID().uuidString).setData(data)
        print("[FCM] comment notification request written")
    }
}

// MARK: - Messaging Delegate
extension FCMService: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        print("[FCM] token refreshed")
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
    case feedComment = "feed_comment"            // 피드 댓글
}
