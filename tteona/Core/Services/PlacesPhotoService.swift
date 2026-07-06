import Foundation

actor PlacesPhotoService {
    static let shared = PlacesPhotoService()
    private init() {}

    private struct PlaceInfo {
        var photoURL: String?
        var category: String?
    }

    private var cache: [String: PlaceInfo] = [:]
    private let wasBaseURL = "https://tteona.kr/api"

    private var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
    }

    // 좌표를 함께 넘기면 관광공사 TourAPI에서 좌표가 가장 가까운 큐레이션 사진을 우선 사용.
    // 좌표 없이 호출하면 기존 동작(Google Places)과 동일.
    func photoURL(for placeName: String, latitude: Double? = nil, longitude: Double? = nil) async -> String? {
        await ensureFetched(placeName, latitude: latitude, longitude: longitude)
        return cache[placeName]?.photoURL
    }

    func placeCategory(for placeName: String, latitude: Double? = nil, longitude: Double? = nil) async -> String? {
        await ensureFetched(placeName, latitude: latitude, longitude: longitude)
        return cache[placeName]?.category
    }

    private func ensureFetched(_ placeName: String, latitude: Double?, longitude: Double?) async {
        guard cache[placeName] == nil else { return }
        cache[placeName] = PlaceInfo()  // 중복 요청 방지용 플레이스홀더

        // 1순위: 관광공사 TourAPI (무료·큐레이션, WAS 경유 + 좌표 기반 선별)
        if let tour = await fetchFromTourAPI(placeName, latitude: latitude, longitude: longitude) {
            cache[placeName] = tour
            return
        }
        // 2순위: Google Places 폴백 (커버리지 보완)
        await fetchAndCache(placeName)
    }

    private func fetchFromTourAPI(_ placeName: String, latitude: Double?, longitude: Double?) async -> PlaceInfo? {
        var comps = URLComponents(string: "\(wasBaseURL)/places/tour-photo")
        var items = [URLQueryItem(name: "name", value: placeName)]
        if let latitude { items.append(URLQueryItem(name: "lat", value: String(latitude))) }
        if let longitude { items.append(URLQueryItem(name: "lng", value: String(longitude))) }
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }

        do {
            let (data, response) = try await APIAuth.get(url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let photoURL = json["url"] as? String, !photoURL.isEmpty else { return nil }
            return PlaceInfo(photoURL: photoURL, category: json["category"] as? String)
        } catch {
            return nil
        }
    }

    private func fetchAndCache(_ placeName: String) async {
        guard !apiKey.isEmpty,
              let url = URL(string: "https://places.googleapis.com/v1/places:searchText")
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("com.seoktaedev.tteona", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.setValue("places.photos,places.types", forHTTPHeaderField: "X-Goog-FieldMask")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["textQuery": placeName])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]],
              let firstPlace = places.first
        else { return }

        // 사진 URL 가져오기
        var photoURL: String?
        if let photos = firstPlace["photos"] as? [[String: Any]],
           let photoName = photos.first?["name"] as? String {
            let mediaStr = "https://places.googleapis.com/v1/\(photoName)/media?maxHeightPx=800&skipHttpRedirect=true"
            if let mediaURL = URL(string: mediaStr) {
                var mediaRequest = URLRequest(url: mediaURL)
                mediaRequest.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
                mediaRequest.setValue("com.seoktaedev.tteona", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
                if let (mediaData, _) = try? await URLSession.shared.data(for: mediaRequest),
                   let mediaJson = try? JSONSerialization.jsonObject(with: mediaData) as? [String: Any],
                   let photoUri = mediaJson["photoUri"] as? String {
                    photoURL = photoUri
                }
            }
        }

        // 카테고리 파싱
        var category: String?
        if let types = firstPlace["types"] as? [String] {
            category = categoryText(from: types)
        }

        cache[placeName] = PlaceInfo(photoURL: photoURL, category: category)
    }

    private func categoryText(from types: [String]) -> String? {
        let priority: [(String, String)] = [
            ("beach", "해변"), ("mountain", "산"), ("national_park", "국립공원"),
            ("university", "대학교"), ("school", "학교"), ("library", "도서관"),
            ("museum", "박물관"), ("art_gallery", "갤러리"),
            ("amusement_park", "놀이공원"), ("zoo", "동물원"), ("aquarium", "수족관"),
            ("stadium", "경기장"), ("park", "공원"),
            ("cafe", "카페"), ("bakery", "베이커리"), ("restaurant", "음식점"),
            ("bar", "바"), ("night_club", "나이트클럽"), ("movie_theater", "영화관"),
            ("shopping_mall", "쇼핑몰"), ("store", "상점"),
            ("lodging", "숙박"), ("spa", "스파"), ("gym", "헬스장"),
            ("hospital", "병원"), ("pharmacy", "약국"),
            ("subway_station", "지하철역"), ("train_station", "기차역"),
            ("tourist_attraction", "관광명소"), ("point_of_interest", "명소"),
        ]
        for (type, label) in priority {
            if types.contains(type) { return label }
        }
        return nil
    }
}
