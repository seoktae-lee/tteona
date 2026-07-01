import Foundation
import FirebaseFirestore

struct PlaceDetail {
    let placeKey: String
    let photos: [String]
    let rating: Double?
    let reviewCount: Int
    let reviews: [GooglePlaceReview]
}

struct GooglePlaceReview: Identifiable {
    let id = UUID()
    let authorName: String
    let rating: Int
    let text: String
    let publishTime: String
}

actor PlaceDetailService {
    static let shared = PlaceDetailService()
    private init() {}

    private var memoryCache: [String: PlaceDetail] = [:]
    private let db = Firestore.firestore()
    private let cacheTTL: TimeInterval = 7 * 24 * 3600
    private let wasBaseURL = "https://tteona.kr/api/places/cache"

    private var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
    }

    func fetchDetail(for placeName: String) async -> PlaceDetail? {
        let key = Self.cacheKey(for: placeName)

        // 1. 메모리 캐시
        if let cached = memoryCache[key] { return cached }

        // 2. PostgreSQL 캐시 (WAS 서버)
        if let cached = await fetchFromWAS(key: key) {
            memoryCache[key] = cached
            return cached
        }

        // 3. Firestore 캐시
        if let cached = await fetchFromFirestore(key: key) {
            memoryCache[key] = cached
            Task { await self.saveToWAS(detail: cached, key: key) }
            return cached
        }

        // 4. Google Places API
        guard let detail = await fetchFromGoogle(placeName: placeName, key: key) else { return nil }
        memoryCache[key] = detail
        await saveToFirestore(detail: detail, key: key)
        Task { await self.saveToWAS(detail: detail, key: key) }
        return detail
    }

    static func cacheKey(for placeName: String) -> String {
        placeName.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .joined(separator: "_")
    }

    // MARK: - WAS PostgreSQL 캐시

    private func fetchFromWAS(key: String) async -> PlaceDetail? {
        guard let url = URL(string: "\(wasBaseURL)?key=\(key)") else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let photos = json["photos"] as? [String] ?? []
        let rating = json["rating"] as? Double
        let reviewCount = json["reviewCount"] as? Int ?? 0
        let rawReviews = json["reviews"] as? [[String: Any]] ?? []
        let reviews = rawReviews.compactMap { r -> GooglePlaceReview? in
            guard let author = r["authorName"] as? String,
                  let rating = r["rating"] as? Int,
                  let text = r["text"] as? String else { return nil }
            return GooglePlaceReview(authorName: author, rating: rating, text: text,
                                     publishTime: r["publishTime"] as? String ?? "")
        }
        return PlaceDetail(placeKey: key, photos: photos, rating: rating,
                           reviewCount: reviewCount, reviews: reviews)
    }

    private func saveToWAS(detail: PlaceDetail, key: String) async {
        guard let url = URL(string: wasBaseURL) else { return }
        let reviewsData: [[String: Any]] = detail.reviews.map {
            ["authorName": $0.authorName, "rating": $0.rating,
             "text": $0.text, "publishTime": $0.publishTime]
        }
        var body: [String: Any] = [
            "cacheKey": key,
            "photos": detail.photos,
            "reviewCount": detail.reviewCount,
            "reviews": reviewsData
        ]
        if let rating = detail.rating { body["rating"] = rating }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Firestore 캐시

    private func fetchFromFirestore(key: String) async -> PlaceDetail? {
        guard let doc = try? await db.collection("placeCache").document(key).getDocument(),
              doc.exists,
              let data = doc.data(),
              let cachedAt = (data["cachedAt"] as? Timestamp)?.dateValue(),
              Date().timeIntervalSince(cachedAt) < cacheTTL
        else { return nil }

        let photos = data["photos"] as? [String] ?? []
        let rating = data["rating"] as? Double
        let reviewCount = data["reviewCount"] as? Int ?? 0
        let rawReviews = data["reviews"] as? [[String: Any]] ?? []
        let reviews = rawReviews.compactMap { r -> GooglePlaceReview? in
            guard let author = r["authorName"] as? String,
                  let rating = r["rating"] as? Int,
                  let text = r["text"] as? String else { return nil }
            return GooglePlaceReview(authorName: author, rating: rating, text: text,
                                     publishTime: r["publishTime"] as? String ?? "")
        }
        return PlaceDetail(placeKey: key, photos: photos, rating: rating,
                           reviewCount: reviewCount, reviews: reviews)
    }

    private func saveToFirestore(detail: PlaceDetail, key: String) async {
        let reviewsData: [[String: Any]] = detail.reviews.map {
            ["authorName": $0.authorName, "rating": $0.rating,
             "text": $0.text, "publishTime": $0.publishTime]
        }
        var data: [String: Any] = [
            "photos": detail.photos,
            "reviewCount": detail.reviewCount,
            "reviews": reviewsData,
            "cachedAt": FieldValue.serverTimestamp()
        ]
        if let rating = detail.rating { data["rating"] = rating }
        try? await db.collection("placeCache").document(key).setData(data)
    }

    // MARK: - Google Places API

    private func fetchFromGoogle(placeName: String, key: String) async -> PlaceDetail? {
        guard !apiKey.isEmpty,
              let url = URL(string: "https://places.googleapis.com/v1/places:searchText")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("com.seoktaedev.tteona", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.setValue(
            "places.photos,places.types,places.rating,places.userRatingCount,places.reviews",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["textQuery": placeName])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]],
              let firstPlace = places.first
        else { return nil }

        // 사진 URL 최대 5장 병렬 fetch
        var photoURLs: [String] = []
        if let photos = firstPlace["photos"] as? [[String: Any]] {
            let names = photos.prefix(5).compactMap { $0["name"] as? String }
            photoURLs = await withTaskGroup(of: String?.self) { group in
                for name in names {
                    group.addTask { await self.fetchPhotoURL(name: name) }
                }
                var urls: [String] = []
                for await url in group { if let url { urls.append(url) } }
                return urls
            }
        }

        let rating = firstPlace["rating"] as? Double
        let reviewCount = firstPlace["userRatingCount"] as? Int ?? 0

        var reviews: [GooglePlaceReview] = []
        if let rawReviews = firstPlace["reviews"] as? [[String: Any]] {
            reviews = rawReviews.compactMap { r -> GooglePlaceReview? in
                guard let author = (r["authorAttribution"] as? [String: Any])?["displayName"] as? String,
                      let rating = r["rating"] as? Int else { return nil }
                let text = (r["text"] as? [String: Any])?["text"] as? String ?? ""
                let publishTime = r["relativePublishTimeDescription"] as? String ?? ""
                return GooglePlaceReview(authorName: author, rating: rating, text: text,
                                         publishTime: publishTime)
            }
        }

        return PlaceDetail(placeKey: key, photos: photoURLs, rating: rating,
                           reviewCount: reviewCount, reviews: reviews)
    }

    private func fetchPhotoURL(name: String) async -> String? {
        let str = "https://places.googleapis.com/v1/\(name)/media?maxHeightPx=800&skipHttpRedirect=true"
        guard let url = URL(string: str) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("com.seoktaedev.tteona", forHTTPHeaderField: "X-Ios-Bundle-Identifier")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["photoUri"] as? String
    }
}
