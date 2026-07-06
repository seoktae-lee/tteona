import Foundation
import FirebaseAuth

/// tteona WAS(tteona.kr) 호출 시 Firebase ID 토큰을 Authorization 헤더로 첨부하는 공용 헬퍼.
/// 서버가 토큰의 uid를 검증해 본인 확인을 하므로, WAS를 부르는 모든 요청은 이걸 거쳐야 한다.
enum APIAuth {
    /// 현재 로그인 유저의 ID 토큰 (SDK가 캐시/자동갱신하므로 매 호출 부담 없음)
    static func bearerToken() async -> String? {
        guard let user = Auth.auth().currentUser else { return nil }
        return try? await user.getIDToken()
    }

    /// 기존 URLRequest에 Authorization 헤더 추가
    static func authorize(_ request: inout URLRequest) async {
        if let token = await bearerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// 인증 헤더가 붙은 요청 생성 (jsonBody가 있으면 Content-Type/바디까지 설정)
    static func request(url: URL, method: String = "GET", jsonBody: [String: Any]? = nil) async -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
        await authorize(&req)
        return req
    }

    /// 인증 헤더가 붙은 GET 요청 실행
    static func get(_ url: URL) async throws -> (Data, URLResponse) {
        let req = await request(url: url)
        return try await URLSession.shared.data(for: req)
    }
}
