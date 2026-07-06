import Foundation

actor PushService {
    static let shared = PushService()
    private init() {}

    private let baseURL = "https://tteona.kr/api/push"

    // 로그인 시 APNs device token을 WAS에 등록
    func registerDeviceToken(userId: String) async {
        guard let token = UserDefaults.standard.string(forKey: "apnsDeviceToken"),
              !token.isEmpty else { return }

        guard let url = URL(string: "\(baseURL)/register") else { return }
        let request = await APIAuth.request(url: url, method: "POST",
                                            jsonBody: ["userId": userId, "token": token])
        _ = try? await URLSession.shared.data(for: request)
    }

    // 코스 좋아요 알림 트리거 (좋아요 누른 쪽 앱에서 호출)
    func notifyCourseLiked(courseOwnerId: String, likerNickname: String, courseName: String) async {
        guard let url = URL(string: "\(baseURL)/course-liked") else { return }
        let request = await APIAuth.request(url: url, method: "POST", jsonBody: [
            "courseOwnerId": courseOwnerId,
            "likerNickname": likerNickname,
            "courseName": courseName
        ])
        _ = try? await URLSession.shared.data(for: request)
    }

    // 코스 따라가기 알림 트리거 (코스 여행 시작 시 호출)
    func notifyCourseFollowed(courseOwnerId: String, followerNickname: String, courseName: String) async {
        guard let url = URL(string: "\(baseURL)/course-followed") else { return }
        let request = await APIAuth.request(url: url, method: "POST", jsonBody: [
            "courseOwnerId": courseOwnerId,
            "followerNickname": followerNickname,
            "courseName": courseName
        ])
        _ = try? await URLSession.shared.data(for: request)
    }
}
