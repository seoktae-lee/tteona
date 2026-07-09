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
    var sigCodes: [String]        // 색칠된 한국 시군구 코드
    var provinceCodes: [String]   // 색칠된 세계 주/도 코드 (ISO 3166-2)
    var countryCodes: [String]    // 방문 국가 ISO3 (국가 카운트용)
    var regionNames: [String]     // 표시용 지역 이름 ("서울 종로구", "Ōsaka" 등)
    var points: [FootprintPoint]  // 경로 보조 표시용 장소 좌표 (순서대로)

    enum CodingKeys: String, CodingKey {
        case courseId, courseName, date, placeCount, sigCodes, provinceCodes, countryCodes, regionNames, points
    }

    // provinceCodes가 없는 과거 문서도 디코딩되도록 관대하게 처리
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = DocumentID(wrappedValue: nil)
        courseId = (try? c.decode(String.self, forKey: .courseId)) ?? ""
        courseName = (try? c.decode(String.self, forKey: .courseName)) ?? ""
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        placeCount = (try? c.decode(Int.self, forKey: .placeCount)) ?? 0
        sigCodes = (try? c.decode([String].self, forKey: .sigCodes)) ?? []
        provinceCodes = (try? c.decode([String].self, forKey: .provinceCodes)) ?? []
        countryCodes = (try? c.decode([String].self, forKey: .countryCodes)) ?? []
        regionNames = (try? c.decode([String].self, forKey: .regionNames)) ?? []
        points = (try? c.decode([FootprintPoint].self, forKey: .points)) ?? []
    }

    init(id: String? = nil, courseId: String, courseName: String, date: Date, placeCount: Int,
         sigCodes: [String], provinceCodes: [String], countryCodes: [String],
         regionNames: [String], points: [FootprintPoint]) {
        self._id = DocumentID(wrappedValue: id)
        self.courseId = courseId
        self.courseName = courseName
        self.date = date
        self.placeCount = placeCount
        self.sigCodes = sigCodes
        self.provinceCodes = provinceCodes
        self.countryCodes = countryCodes
        self.regionNames = regionNames
        self.points = points
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
    var provinceCodes: Set<String> = []
    var countryCodes: Set<String> = []

    var isEmpty: Bool { sigCodes.isEmpty && provinceCodes.isEmpty && countryCodes.isEmpty }
}
