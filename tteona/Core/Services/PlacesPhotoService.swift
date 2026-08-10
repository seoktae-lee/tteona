import Foundation
import CoreLocation

actor PlacesPhotoService {
    static let shared = PlacesPhotoService()
    private init() {}

    private struct PlaceInfo: Codable {
        var photoURL: String?
        var category: String?
        /// 디스크 캐시 만료 시각. 메모리 전용 항목은 nil.
        var expiresAt: Date?
    }

    private var cache: [String: PlaceInfo] = [:]
    private let wasBaseURL = "https://tteona.kr/api"

    /// 캐시 키에 **좌표를 함께 넣는다.**
    /// 이름만 키로 쓰면 '스타벅스'·'본점' 같은 흔한 이름이 전국에서 한 칸을 공유해,
    /// 먼저 조회된 다른 도시의 사진이 그대로 재사용됐다 — 엉뚱한 사진의 한 원인.
    /// 약 100m 격자로 뭉개 같은 장소는 계속 캐시를 맞히게 한다.
    private func cacheKey(_ name: String, _ lat: Double?, _ lng: Double?) -> String {
        guard let lat, let lng else { return name }
        return String(format: "%@|%.3f,%.3f", name, lat, lng)
    }

    /// 사용자가 실제로 서 있던 좌표에서 이만큼 벗어난 후보는 다른 장소로 본다.
    private let maxMatchKm: Double = 1.5

    private var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
    }

    // 좌표를 함께 넘기면 관광공사 TourAPI에서 좌표가 가장 가까운 큐레이션 사진을 우선 사용.
    // 좌표 없이 호출하면 기존 동작(Google Places)과 동일.
    func photoURL(for placeName: String, latitude: Double? = nil, longitude: Double? = nil) async -> String? {
        await ensureFetched(placeName, latitude: latitude, longitude: longitude)
        return cache[cacheKey(placeName, latitude, longitude)]?.photoURL
    }

    func placeCategory(for placeName: String, latitude: Double? = nil, longitude: Double? = nil) async -> String? {
        await ensureFetched(placeName, latitude: latitude, longitude: longitude)
        return cache[cacheKey(placeName, latitude, longitude)]?.category
    }

    private func ensureFetched(_ placeName: String, latitude: Double?, longitude: Double?) async {
        let key = cacheKey(placeName, latitude, longitude)
        loadDiskCacheIfNeeded()
        guard cache[key] == nil else { return }
        cache[key] = PlaceInfo()  // 중복 요청 방지용 플레이스홀더

        // 1순위: 관광공사 TourAPI (무료·큐레이션, WAS 경유 + 좌표 기반 선별)
        if var tour = await fetchFromTourAPI(placeName, latitude: latitude, longitude: longitude) {
            tour.expiresAt = Date().addingTimeInterval(30 * 86_400)
            cache[key] = tour
            persistDiskCache()
            return
        }
        // 2순위: Google Places 폴백 (커버리지 보완)
        await fetchAndCache(placeName, latitude: latitude, longitude: longitude, key: key)

        // 사진을 못 찾은 것도 결과다. 남겨두지 않으면 사진 없는 장소를 볼 때마다
        // 유료 검색을 다시 때린다. 다만 짧게만 — 나중에 등록될 수 있으니.
        if cache[key]?.photoURL == nil {
            cache[key] = PlaceInfo(photoURL: nil, category: cache[key]?.category,
                                   expiresAt: Date().addingTimeInterval(3 * 86_400))
            persistDiskCache()
        }
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

    private func fetchAndCache(_ placeName: String, latitude: Double?, longitude: Double?, key: String) async {
        guard !apiKey.isEmpty,
              let url = URL(string: "https://places.googleapis.com/v1/places:searchText")
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("com.seoktaedev.tteona", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        // location까지 받아야 "이게 정말 그 장소인지" 검증할 수 있다
        request.setValue("places.photos,places.types,places.location",
                         forHTTPHeaderField: "X-Goog-FieldMask")

        // 이름만 던지면 전 세계에서 가장 유명한 동명 장소가 1등으로 온다.
        // 촬영 좌표를 편향으로 넘겨 그 동네 안에서 찾게 한다.
        var body: [String: Any] = ["textQuery": placeName]
        if let latitude, let longitude {
            body["locationBias"] = [
                "circle": ["center": ["latitude": latitude, "longitude": longitude],
                           "radius": 2000.0]
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]]
        else { return }

        // 편향은 어디까지나 '편향'이라 밖의 결과도 섞여 온다. 실제 거리로 한 번 더 거른다.
        // 좌표를 모르면 예전처럼 1등을 쓴다(그 경우엔 더 나은 근거가 없다).
        guard let firstPlace = nearestPlace(in: places, latitude: latitude, longitude: longitude)
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

        // Google 사진 URL은 서명이 붙어 있어 오래 두면 깨진다 — 짧게만 들고 있는다.
        cache[key] = PlaceInfo(photoURL: photoURL, category: category,
                               expiresAt: Date().addingTimeInterval(7 * 86_400))
        persistDiskCache()
    }

    /// 촬영 좌표에서 maxMatchKm 안에 있는 후보 중 가장 가까운 것.
    /// 하나도 없으면 nil — 사진을 안 띄우는 편이 남의 장소 사진을 띄우는 것보다 낫다.
    private func nearestPlace(in places: [[String: Any]],
                              latitude: Double?, longitude: Double?) -> [String: Any]? {
        guard let latitude, let longitude else { return places.first }
        let origin = CLLocation(latitude: latitude, longitude: longitude)

        let candidates: [(place: [String: Any], meters: Double)] = places.compactMap { place in
            guard let loc = place["location"] as? [String: Any],
                  let lat = loc["latitude"] as? Double,
                  let lng = loc["longitude"] as? Double else { return nil }
            return (place, origin.distance(from: CLLocation(latitude: lat, longitude: lng)))
        }
        return candidates
            .filter { $0.meters <= maxMatchKm * 1000 }
            .min { $0.meters < $1.meters }?
            .place
    }

    // MARK: - 디스크 캐시
    //
    // TourAPI 이름 규칙을 조인 뒤로 관광지가 아닌 장소는 대부분 Google Places로 넘어간다.
    // Google 텍스트 검색과 사진 요청은 **호출당 과금**이라, 앱을 껐다 켤 때마다 같은 코스를
    // 다시 조회하면 정확도를 돈으로 바꾸는 꼴이 된다. 조회 결과를 기기에 남겨 재사용한다.
    private static let diskURL: URL? = {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("place-photos.json")
    }()
    private var diskLoaded = false

    private func loadDiskCacheIfNeeded() {
        guard !diskLoaded else { return }
        diskLoaded = true
        guard let url = Self.diskURL,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: PlaceInfo].self, from: data)
        else { return }
        let now = Date()
        for (key, info) in stored where (info.expiresAt ?? .distantPast) > now {
            cache[key] = info
        }
    }

    private func persistDiskCache() {
        guard let url = Self.diskURL else { return }
        // 만료됐거나 조회 중인 플레이스홀더는 남기지 않는다
        let now = Date()
        let keep = cache.filter { (_, info) in (info.expiresAt ?? .distantPast) > now }
        guard let data = try? JSONEncoder().encode(keep) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func categoryText(from types: [String]) -> String? {
        let priority: [(String, String)] = [
            ("beach", "place.category.beach"), ("mountain", "place.category.mountain"), ("national_park", "place.category.nationalPark"),
            ("university", "place.category.university"), ("school", "place.category.school"), ("library", "place.category.library"),
            ("museum", "place.category.museum"), ("art_gallery", "place.category.artGallery"),
            ("amusement_park", "place.category.amusementPark"), ("zoo", "place.category.zoo"), ("aquarium", "place.category.aquarium"),
            ("stadium", "place.category.stadium"), ("park", "place.category.park"),
            ("cafe", "place.category.cafe"), ("bakery", "place.category.bakery"), ("restaurant", "place.category.restaurant"),
            ("bar", "place.category.bar"), ("night_club", "place.category.nightClub"), ("movie_theater", "place.category.movieTheater"),
            ("shopping_mall", "place.category.shoppingMall"), ("store", "place.category.store"),
            ("lodging", "place.category.lodging"), ("spa", "place.category.spa"), ("gym", "place.category.gym"),
            ("hospital", "place.category.hospital"), ("pharmacy", "place.category.pharmacy"),
            ("subway_station", "place.category.subwayStation"), ("train_station", "place.category.trainStation"),
            ("tourist_attraction", "place.category.touristAttraction"), ("point_of_interest", "place.category.pointOfInterest"),
        ]
        for (type, key) in priority {
            if types.contains(type) { return L(key) }
        }
        return nil
    }
}
