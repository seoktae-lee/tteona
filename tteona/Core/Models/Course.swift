import Foundation
import CoreLocation
import FirebaseFirestore

struct Place: Identifiable, Codable, Equatable {
    var id: String { "\(order)_\(placeName)" }
    var order: Int
    var placeName: String
    var latitude: Double
    var longitude: Double
    var clipFileName: String?  // 나의 오늘 촬영 클립 파일명 — reorder와 무관하게 파일 추적

    // 이 **장소**의 출처 — 방송·유튜브에 소개된 곳이면 채운다.
    // 코스가 아니라 장소에 다는 이유: 큐레이션 코스의 '점심식사' 자리 하나만 방송 맛집으로
    // 바뀌는 게 실제 쓰임새다. 코스 전체가 한 프로그램에서 온 경우는 오히려 드물다.
    // 사람 이름·얼굴은 넣지 않는다 — 프로그램/채널명만. (성명·초상 무단사용 회피)
    var source: String?         // 예: "또간집", "전현무계획"
    var sourceVideoId: String?  // 유튜브 영상 ID. 재호스팅하지 않고 공식 임베드로만 재생한다

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum CodingKeys: String, CodingKey {
        case order, placeName, latitude, longitude, clipFileName, source, sourceVideoId
    }
}

/// 코스 근처의 추천 식당.
///
/// **코스의 places에 끼워 넣지 않는다.** 이용약관 11조에 "원 데이터를 임의로 수정하지 않는다"고
/// 명시했고, 장소를 추가하는 것은 표기 정리의 범위를 넘는다. 원본 코스는 그대로 두고
/// 곁들임으로만 보여주며, 실제로 넣을지는 사용자가 세션을 시작할 때 고른다.
struct NearbyFood: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var latitude: Double
    var longitude: Double
    /// 코스의 어느 장소 근처인지 — "무엇의 곁인지"를 알아야 사용자가 동선을 가늠한다
    var nearPlaceName: String
    var distanceM: Int

    /// 구글 평점과 리뷰 수. 추천 목록을 고를 때 이미 걸렀지만(3.7 미만 제외),
    /// 화면에도 보여줘야 사용자가 들를지 스스로 판단할 수 있다.
    /// 구글에 등재되지 않은 지역 노포는 nil이며, 그것만으로 나쁜 집은 아니다.
    var rating: Double?
    var ratingCount: Int?

    /// 방송·유튜브 출처. 지금은 비어 있고, 방송 맛집 DB가 붙는 단계에서 채운다.
    var source: String?
    var sourceVideoId: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum CodingKeys: String, CodingKey {
        case name, latitude, longitude, nearPlaceName, distanceM, rating, ratingCount, source, sourceVideoId
    }

    /// 장소 상세 시트(PlaceDetailSheet)가 Place를 받으므로 그대로 넘길 수 있게 변환한다.
    /// order는 코스 동선의 순번인데 추천 맛집은 동선에 없으므로 0으로 둔다.
    var asPlace: Place {
        Place(order: 0, placeName: name, latitude: latitude, longitude: longitude)
    }
}

struct Course: Identifiable, Codable {
    @DocumentID var id: String?
    var courseId: String
    var authorId: String
    var courseName: String
    var tag: CourseTag
    var region: String
    var likeCount: Int
    var createdAt: Date
    var places: [Place]
    var mainPlaceOrder: Int? = nil   // 유저가 지정한 대표 장소의 order (미지정 시 자동 선택)

    /// 공식 큐레이션 코스인가. **지도 쿼리·핀·정렬의 기준**이라 source 유무로 대신하지 않는다.
    /// (관광공사 코스 / 제휴 크리에이터 코스는 출처 성격이 달라 한 필드로 겸할 수 없다)
    ///
    /// **반드시 Optional이어야 한다.** `Bool = false`로 두면 기본값이 memberwise init에만
    /// 적용되고, 자동 생성 init(from:)은 키가 없을 때 keyNotFound로 던진다 —
    /// 이 필드가 없는 기존 코스 문서가 통째로 디코딩에서 탈락해 지도에서 사라진다.
    /// (AppUser.swift가 isVerified로 겪은 것과 같은 함정. 읽을 때는 isCurated를 쓸 것)
    var curated: Bool? = nil

    /// 큐레이션 출처 표기 — "한국관광공사", "제휴:○○채널". 화면에 그대로 노출된다.
    /// 공공데이터 이용조건상 출처 표기 의무가 있으므로 curated면 반드시 채운다.
    var curationSource: String? = nil

    /// 대표 장소의 위도 밴드("37.5°N", 0.1° 단위 ≈ 11km). **큐레이션 코스의 지역 검색 키다.**
    ///
    /// UGC 코스는 `region`에 위도 문자열이 들어가 있어 fetchCoursesNear가 그걸 쓰지만,
    /// 큐레이션 코스는 화면에 "서울"·"경기 파주시"처럼 읽히는 지역명을 보여줘야 해서
    /// region을 좌표로 쓸 수 없다. 그래서 검색용 밴드를 별도 필드로 둔다.
    /// (전국 900여 개를 앱 진입마다 통째로 받는 건 낭비라 지역 로드가 필요하다)
    var latBand: String? = nil

    /// 코스 근처 추천 식당. **Optional이어야 한다** — 이 필드가 없는 기존 문서를 디코딩할 때
    /// 자동 생성 init(from:)이 keyNotFound로 던진다(curated로 이미 한 번 겪었다).
    var nearbyFood: [NearbyFood]? = nil

    /// 위도 → 밴드 문자열. 주입 스크립트와 앱이 같은 규칙을 써야 하므로 여기에 둔다.
    static func latBand(for latitude: Double) -> String {
        String(format: "%.1f°N", (latitude * 10).rounded() / 10)
    }
}

extension Array where Element == Place {
    // 표시 전용 — 바로 연속되는 동일 장소(같은 곳에서 여러 번 촬영)를 하나로 접고 1부터 재번호.
    // 떨어져서 다시 방문한 동일 장소는 그대로 남는다. 저장·Vlog 합성은 원본 places를 사용할 것.
    var mergedForDisplay: [Place] {
        var result: [Place] = []
        for place in sorted(by: { $0.order < $1.order }) {
            if place.placeName == result.last?.placeName { continue }
            result.append(place)
        }
        return result.enumerated().map { idx, place in
            Place(order: idx + 1, placeName: place.placeName,
                  latitude: place.latitude, longitude: place.longitude,
                  clipFileName: place.clipFileName,
                  source: place.source, sourceVideoId: place.sourceVideoId)
        }
    }
}

extension Course {
    // 유저에게 보여줄 장소 목록 — 연속 중복이 병합된 표시용 (원본 places는 그대로 유지)
    var displayPlaces: [Place] { places.mergedForDisplay }

    // 대표 장소 — 핀·썸네일·날씨·추천의 기준점.
    // 유저가 지정했으면 그 장소, 아니면 자동 선택(경유지 후순위), 그것도 없으면 첫 장소.
    var mainPlace: Place? {
        if let order = mainPlaceOrder, let p = places.first(where: { $0.order == order }) {
            return p
        }
        return Course.autoPickMainPlace(places)
    }

    // 경유지성 장소(역·주차장·터미널 등)를 후순위로 두고 명소성 장소를 대표로 자동 선택
    static func autoPickMainPlace(_ places: [Place]) -> Place? {
        guard !places.isEmpty else { return nil }
        return places.first { !isTransitLike($0.placeName) } ?? places.first
    }

    static func isTransitLike(_ name: String) -> Bool {
        if name.hasSuffix("역") { return true }   // OO역 (지하철/기차역)
        let keywords = ["주차장", "터미널", "정류장", "환승센터", "휴게소", "톨게이트", "공영주차"]
        return keywords.contains { name.contains($0) }
    }
}

enum CourseTag: String, Codable, CaseIterable {
    case couple = "커플"
    case friends = "친구"
    case family = "가족"
    case solo = "혼자"

    var emoji: String {
        switch self {
        case .couple: return "💑"
        case .friends: return "👫"
        case .family: return "👨‍👩‍👧‍👦"
        case .solo: return "🧍"
        }
    }

    /// 홈 지도에 찍히는 태그별 커스텀 핀 에셋 — 취향 선택 UI도 같은 핀으로 보여준다
    var pinImageName: String {
        switch self {
        case .couple:  return "pin_couple"
        case .friends: return "pin_friends"
        case .family:  return "pin_family"
        case .solo:    return "pin_solo"
        }
    }

    // rawValue는 Firestore 저장값(한글)이므로 화면 표시는 항상 displayName을 사용할 것
    var displayName: String {
        switch self {
        case .couple: return L("tag.couple")
        case .friends: return L("tag.friends")
        case .family: return L("tag.family")
        case .solo: return L("tag.solo")
        }
    }
}

let courseRegions = ["서울", "부산", "제주", "경주", "강릉", "전주", "기타"]

// Firestore의 region 값은 한 가지 형태가 아니다: 초기 코스는 courseRegions의 한글 지역명을,
// 즉석 세션은 "37.5°N" 같은 좌표 문자열을 저장한다. 아는 지역명만 번역하고 나머지는 원문을 돌려준다.
private let courseRegionKeys: [String: String] = [
    "서울": "region.seoul", "부산": "region.busan", "제주": "region.jeju",
    "경주": "region.gyeongju", "강릉": "region.gangneung", "전주": "region.jeonju",
    "기타": "region.other",
]

extension Course {
    /// 큐레이션 여부 — curated는 기존 문서 호환 때문에 Optional이므로 판정은 항상 이걸 쓴다.
    var isCurated: Bool { curated ?? false }

    /// 화면에 보여줄 출처 기관명.
    ///
    /// Firestore에는 한글("한국관광공사")로 저장되므로 그대로 그리면 영어·일본어 사용자에게
    /// 한글이 노출된다. 아는 기관은 번역하고, 모르는 값(제휴 크리에이터 등)은 원문을 쓴다.
    /// **공공데이터 이용조건상 출처 표기는 의무**라 큐레이션 코스라면 반드시 채워져 있어야 한다.
    var localizedCurationSource: String? {
        guard let source = curationSource, !source.isEmpty else { return nil }
        return source == "한국관광공사" ? L("source.kto") : source
    }

    /// 코스 안에서 이동하는 총 거리(km). 좌표만으로 즉시 구할 수 있어 API가 필요 없다.
    /// (교통수단별 실측 소요시간은 CourseTravelInfo가 따로 조회한다)
    var totalDistanceKm: Double {
        let ps = displayPlaces
        guard ps.count >= 2 else { return 0 }
        return zip(ps, ps.dropFirst()).reduce(0.0) { sum, pair in
            sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        } / 1000
    }

    /// 화면 표시용 지역명 — region을 그대로 그리면 영어/일본어 유저에게 한글이 노출된다.
    var localizedRegion: String {
        guard let key = courseRegionKeys[region] else { return region }
        return L(key)
    }
}
