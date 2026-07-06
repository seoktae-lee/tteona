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

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum CodingKeys: String, CodingKey {
        case order, placeName, latitude, longitude, clipFileName
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
                  clipFileName: place.clipFileName)
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
}

let courseRegions = ["서울", "부산", "제주", "경주", "강릉", "전주", "기타"]
