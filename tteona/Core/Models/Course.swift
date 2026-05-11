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
