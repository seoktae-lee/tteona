import Foundation
import FirebaseFirestore

// MARK: - 발자취 기록
/// 브이로그를 만들 때마다 1건씩 쌓이는 여행 기록.
/// users/{uid}/footprints/{sessionId} — 같은 세션에서 재생성해도 중복 적재되지 않는다.
struct FootprintRecord: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var courseId: String
    var courseName: String
    var date: Date
    var placeCount: Int
    var sigCodes: [String]       // 색칠된 한국 시군구 코드
    var countryCodes: [String]   // 색칠된 국가 ISO3 코드
    var regionNames: [String]    // 표시용 지역 이름 ("서울 종로구", "Japan" 등)
    var points: [FootprintPoint] // 경로 보조 표시용 장소 좌표 (순서대로)

    enum CodingKeys: String, CodingKey {
        case courseId, courseName, date, placeCount, sigCodes, countryCodes, regionNames, points
    }
}

/// 경로 표시용 좌표 한 점
struct FootprintPoint: Codable, Equatable {
    var lat: Double
    var lng: Double
}

// MARK: - 발자취 요약 (지도 색칠용)
/// 유저 문서에 누적되는 방문 지역 집합 — 지도 렌더링은 이것만 있으면 된다.
struct FootprintSummary: Equatable {
    var sigCodes: Set<String> = []
    var countryCodes: Set<String> = []

    var isEmpty: Bool { sigCodes.isEmpty && countryCodes.isEmpty }
}
