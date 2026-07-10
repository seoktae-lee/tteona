import Foundation

actor PushService {
    static let shared = PushService()
    private init() {}

    private let baseURL = "https://tteona.kr/api/push"

    /// 로그인 시·언어 변경 시 APNs device token을 WAS에 등록한다.
    /// `lang`은 서버가 알림 문구를 어느 언어로 쓸지 정하는 값 — 호출부(MainActor)에서 넘긴다.
    func registerDeviceToken(userId: String, lang: String) async {
        guard let token = UserDefaults.standard.string(forKey: "apnsDeviceToken"),
              !token.isEmpty else { return }

        guard let url = URL(string: "\(baseURL)/register") else { return }
        let request = await APIAuth.request(url: url, method: "POST",
                                            jsonBody: ["userId": userId, "token": token, "lang": lang])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// 로그아웃 시 이 기기의 토큰을 해제한다. 남겨두면 같은 기기에 로그인한
    /// 다음 사용자의 화면에 이전 계정의 알림이 뜬다.
    /// Firebase 세션이 살아있을 때(= signOut 직전) 호출해야 인증을 통과한다.
    func unregisterDeviceToken() async {
        guard let token = UserDefaults.standard.string(forKey: "apnsDeviceToken"),
              !token.isEmpty,
              let url = URL(string: "\(baseURL)/unregister") else { return }

        let request = await APIAuth.request(url: url, method: "POST",
                                            jsonBody: ["token": token])
        _ = try? await URLSession.shared.data(for: request)
    }

    // 코스 좋아요 알림 트리거 (좋아요 누른 쪽 앱에서 호출)
    // courseId를 함께 보내야 수신자가 알림을 탭했을 때 그 코스를 열 수 있다.
    func notifyCourseLiked(courseOwnerId: String, likerNickname: String,
                           courseName: String, courseId: String) async {
        guard let url = URL(string: "\(baseURL)/course-liked") else { return }
        let request = await APIAuth.request(url: url, method: "POST", jsonBody: [
            "courseOwnerId": courseOwnerId,
            "likerNickname": likerNickname,
            "courseName": courseName,
            "courseId": courseId
        ])
        _ = try? await URLSession.shared.data(for: request)
    }

    // 코스 따라가기 알림 트리거 (코스 여행 시작 시 호출)
    func notifyCourseFollowed(courseOwnerId: String, followerNickname: String,
                              courseName: String, courseId: String) async {
        guard let url = URL(string: "\(baseURL)/course-followed") else { return }
        let request = await APIAuth.request(url: url, method: "POST", jsonBody: [
            "courseOwnerId": courseOwnerId,
            "followerNickname": followerNickname,
            "courseName": courseName,
            "courseId": courseId
        ])
        _ = try? await URLSession.shared.data(for: request)
    }
}
