import Foundation

struct TravelStats: Decodable {
    let coursesCreated: Int
    let placesInCourses: Int
    let likesReceived: Int
    let groups: Int
    let placesVisited: Int
    let activeDays: Int
}

struct CreatorRank: Decodable, Identifiable {
    let rank: Int
    let userId: String
    let nickname: String
    let isVerified: Bool
    let profileImageUrl: String?
    let likes: Int
    let courses: Int
    var id: String { userId }
}

enum StatsEvent: String {
    case courseCreated = "course_created"
    case placeVisited  = "place_visited"
    case courseLiked   = "course_liked"
    case courseShared  = "course_shared"
}

actor StatsService {
    static let shared = StatsService()
    private let baseURL = "https://tteona.kr/api"

    // MARK: - 개인 누적 통계

    func fetchMyStats(userId: String) async -> TravelStats? {
        guard let url = URL(string: "\(baseURL)/users/\(userId)/stats") else { return nil }
        do {
            let (data, _) = try await APIAuth.get(url)
            return try JSONDecoder().decode(TravelStats.self, from: data)
        } catch {
            print("[StatsService] fetch error:", error)
            return nil
        }
    }

    // MARK: - 이벤트 적재 (fire-and-forget)

    func postEvent(_ event: StatsEvent, userId: String) async {
        guard let url = URL(string: "\(baseURL)/stats/event") else { return }
        let req = await APIAuth.request(url: url, method: "POST",
                                        jsonBody: ["userId": userId, "type": event.rawValue])
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - 크리에이터 랭킹

    /// 실패(네트워크 오류·태스크 취소)와 "정말 랭킹이 비어 있음"을 구분한다.
    /// nil이면 호출부가 기존 목록을 유지해야 한다 — 빈 배열로 덮으면 스트립이 통째로 사라진다.
    func fetchCreatorRanking() async -> [CreatorRank]? {
        guard let url = URL(string: "\(baseURL)/creators/ranking") else { return nil }
        do {
            let (data, _) = try await APIAuth.get(url)
            struct Response: Decodable { let ranking: [CreatorRank] }
            return try JSONDecoder().decode(Response.self, from: data).ranking
        } catch {
            print("[StatsService] ranking error:", error)
            return nil
        }
    }

    // MARK: - 콘텐츠 모더레이션 (서버 텍스트 검사, 실패 시 통과)

    func isTextAllowed(_ text: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/moderate") else { return true }
        let req = await APIAuth.request(url: url, method: "POST", jsonBody: ["text": text])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return !(json?["blocked"] as? Bool ?? false)
        } catch {
            return true // 네트워크 실패 시 막지 않음
        }
    }
}
