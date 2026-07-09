import Foundation
import Combine
import FirebaseFirestore

// MARK: - 발자취 서비스
/// 브이로그 생성 시 방문 지역을 기록하고, 프로필 지도에 쓸 발자취를 조회한다.
/// - 색칠 집합: users/{uid} 문서의 visitedSigCodes / visitedCountryCodes (arrayUnion 누적)
/// - 타임라인: users/{uid}/footprints/{sessionId} 서브컬렉션
@MainActor
final class FootprintService: ObservableObject {
    static let shared = FootprintService()

    /// 내 발자취 요약 — 기록 직후 프로필 탭이 즉시 반영되도록 공유 상태로 보관
    @Published var mySummary = FootprintSummary()
    /// 마지막으로 새로 칠해진 지역 코드 — 프로필 탭 진입 시 하이라이트 연출용
    @Published var lastNewCodes: Set<String> = []

    private let db = Firestore.firestore()

    // MARK: 기록 (브이로그 생성 성공 시)

    /// 코스의 장소들을 지역으로 판정해 발자취를 적재한다. 실패해도 앱 흐름을 막지 않는다(fire-and-forget).
    func record(course: Course, sessionId: String, userId: String) async {
        // 지역 판정은 CPU 작업 — 백그라운드에서 수행
        let places = course.places
        let resolved: [(place: Place, region: FootprintAtlas.ResolvedRegion)] = await Task.detached(priority: .utility) {
            FootprintAtlas.shared.ensureLoaded()
            return places.map { ($0, FootprintAtlas.shared.resolve(lat: $0.latitude, lng: $0.longitude)) }
        }.value

        var sigCodes: [String] = []
        var countryCodes: [String] = []
        var regionNames: [String] = []
        for (_, region) in resolved {
            if let sig = region.sig, !sigCodes.contains(sig.code) {
                sigCodes.append(sig.code)
                regionNames.append(sig.name)
            }
            if let country = region.country, !countryCodes.contains(country.code) {
                countryCodes.append(country.code)
                if country.code != "KOR" { regionNames.append(country.name) }
            }
        }
        guard !sigCodes.isEmpty || !countryCodes.isEmpty else {
            print("[Footprint] no region resolved — skip")
            return
        }

        let record = FootprintRecord(
            courseId: course.courseId,
            courseName: course.courseName,
            date: Date(),
            placeCount: places.count,
            sigCodes: sigCodes,
            countryCodes: countryCodes,
            regionNames: regionNames,
            points: places.sorted { $0.order < $1.order }
                .map { FootprintPoint(lat: $0.latitude, lng: $0.longitude) }
        )

        do {
            // 새로 칠해지는 지역 계산 (하이라이트 연출용) — 기존 요약과 비교
            let newCodes = Set(sigCodes).subtracting(mySummary.sigCodes)
                .union(Set(countryCodes).subtracting(mySummary.countryCodes))

            // 세션ID를 문서ID로 → 같은 세션 재생성 시 덮어쓰기(중복 방지)
            try db.collection("users").document(userId)
                .collection("footprints").document(sessionId)
                .setData(from: record)
            try await db.collection("users").document(userId).updateData([
                "visitedSigCodes": FieldValue.arrayUnion(sigCodes),
                "visitedCountryCodes": FieldValue.arrayUnion(countryCodes)
            ])

            mySummary.sigCodes.formUnion(sigCodes)
            mySummary.countryCodes.formUnion(countryCodes)
            if !newCodes.isEmpty { lastNewCodes = newCodes }
            print("[Footprint] recorded sig=\(sigCodes) country=\(countryCodes)")
        } catch {
            print("[Footprint] record failed:", error.localizedDescription)
        }
    }

    // MARK: 조회

    /// 유저의 방문 지역 요약 (본인이면 공유 상태도 갱신)
    func fetchSummary(userId: String, isMe: Bool = false) async -> FootprintSummary {
        let doc = try? await db.collection("users").document(userId).getDocument()
        let data = doc?.data()
        var summary = FootprintSummary()
        summary.sigCodes = Set(data?["visitedSigCodes"] as? [String] ?? [])
        summary.countryCodes = Set(data?["visitedCountryCodes"] as? [String] ?? [])
        if isMe { mySummary = summary }
        return summary
    }

    /// 발자취 타임라인 (최신순)
    func fetchFootprints(userId: String, limit: Int = 60) async -> [FootprintRecord] {
        let snapshot = try? await db.collection("users").document(userId)
            .collection("footprints")
            .order(by: "date", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot?.documents.compactMap { try? $0.data(as: FootprintRecord.self) } ?? []
    }

    /// 특정 유저가 올린 코스 (프로필의 코스 목록용)
    func fetchCourses(authorId: String, limit: Int = 50) async -> [Course] {
        let snapshot = try? await db.collection("courses")
            .whereField("authorId", isEqualTo: authorId)
            .limit(to: limit)
            .getDocuments()
        let courses = snapshot?.documents.compactMap { try? $0.data(as: Course.self) } ?? []
        return courses.sorted { $0.createdAt > $1.createdAt }
    }

    /// 닉네임 prefix 검색 (유저 찾기)
    func searchUsers(nickname query: String, limit: Int = 20) async -> [AppUser] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let snapshot = try? await db.collection("users")
            .whereField("nickname", isGreaterThanOrEqualTo: q)
            .whereField("nickname", isLessThan: q + "\u{f8ff}")
            .limit(to: limit)
            .getDocuments()
        return snapshot?.documents.compactMap { try? $0.data(as: AppUser.self) } ?? []
    }

    /// 로그아웃/계정 전환 시 로컬 상태 정리
    func clear() {
        mySummary = FootprintSummary()
        lastNewCodes = []
    }
}
