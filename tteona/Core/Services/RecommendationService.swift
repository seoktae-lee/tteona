import Foundation

struct RecommendResponse: Decodable {
    let courseIds: [String]
}

actor RecommendationService {
    static let shared = RecommendationService()
    private let baseURL = "https://tteona.kr/api/courses/recommend"

    func fetchRecommended(
        userId: String?,
        lat: Double?,
        lng: Double?,
        tag: CourseTag? = nil,
        limit: Int = 20
    ) async -> [String] {
        var components = URLComponents(string: baseURL)!
        var items: [URLQueryItem] = [.init(name: "limit", value: "\(limit)")]
        if let userId { items.append(.init(name: "userId", value: userId)) }
        if let lat    { items.append(.init(name: "lat",    value: "\(lat)")) }
        if let lng    { items.append(.init(name: "lng",    value: "\(lng)")) }
        if let tag    { items.append(.init(name: "tag",    value: tag.rawValue)) }
        components.queryItems = items

        guard let url = components.url else { return [] }
        do {
            let (data, _) = try await APIAuth.get(url)
            return try JSONDecoder().decode(RecommendResponse.self, from: data).courseIds
        } catch {
            print("[RecommendationService] error:", error)
            return []
        }
    }
}
