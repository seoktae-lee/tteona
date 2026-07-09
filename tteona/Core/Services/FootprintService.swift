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
    /// 그중 대표(최다 체류) 신규 지역 코드 — 카메라가 여기로 날아간다
    @Published var lastPrimaryNewCode: String? = nil

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

        // 장소(=촬영 클립) 하나하나를 지역으로 집계 — "가장 많이 머문 지역"이 대표가 되도록.
        // 첫 장소가 아니라 체류 빈도가 기준이므로, 잠깐 스친 환승지가 대표로 뽑히지 않는다.
        // 한국은 시군구, 해외는 주/도(admin-1) 단위로 색칠한다.
        var sigCount: [String: Int] = [:]
        var sigName: [String: String] = [:]
        var provCount: [String: Int] = [:]
        var provName: [String: String] = [:]
        var countryCount: [String: Int] = [:]
        for (_, region) in resolved {
            if let sig = region.sig {
                sigCount[sig.code, default: 0] += 1
                sigName[sig.code] = sig.name
            } else if let province = region.province {
                // 한국이 아닌 곳만 주/도로 색칠 (한국은 시군구가 대표)
                provCount[province.code, default: 0] += 1
                provName[province.code] = province.name
            }
            if let country = region.countryCode {
                countryCount[country, default: 0] += 1
            }
        }
        // 머문 횟수 내림차순 → 동률이면 코드순(결정적). 첫 원소가 최다 체류지.
        let sigCodes = sigCount.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let provinceCodes = provCount.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let countryCodes = countryCount.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        // 표시용 이름: 최다 체류 시군구 → …, 이어서 해외 주/도 (체류순)
        var regionNames = sigCodes.compactMap { sigName[$0] }
        regionNames += provinceCodes.compactMap { provName[$0] }

        guard !sigCodes.isEmpty || !provinceCodes.isEmpty else {
            print("[Footprint] no region resolved — skip")
            return
        }

        let record = FootprintRecord(
            courseId: course.courseId,
            courseName: course.courseName,
            date: Date(),
            placeCount: places.count,
            sigCodes: sigCodes,
            provinceCodes: provinceCodes,
            countryCodes: countryCodes,
            regionNames: regionNames,
            points: places.sorted { $0.order < $1.order }
                .map { FootprintPoint(lat: $0.latitude, lng: $0.longitude) }
        )

        do {
            // 새로 칠해지는 지역 계산 (하이라이트 연출용) — 기존 요약과 비교
            let newCodes = Set(sigCodes).subtracting(mySummary.sigCodes)
                .union(Set(provinceCodes).subtracting(mySummary.provinceCodes))

            // 세션ID를 문서ID로 → 같은 세션 재생성 시 덮어쓰기(중복 방지)
            try db.collection("users").document(userId)
                .collection("footprints").document(sessionId)
                .setData(from: record)
            try await db.collection("users").document(userId).updateData([
                "visitedSigCodes": FieldValue.arrayUnion(sigCodes),
                "visitedProvinceCodes": FieldValue.arrayUnion(provinceCodes),
                "visitedCountryCodes": FieldValue.arrayUnion(countryCodes)
            ])

            mySummary.sigCodes.formUnion(sigCodes)
            mySummary.provinceCodes.formUnion(provinceCodes)
            mySummary.countryCodes.formUnion(countryCodes)
            if !newCodes.isEmpty {
                lastNewCodes = newCodes
                // 대표 신규 지역 = 체류순 정렬(시군구 우선)에서 처음으로 등장하는 새 지역
                lastPrimaryNewCode = (sigCodes + provinceCodes).first { newCodes.contains($0) }
            }
            print("[Footprint] recorded sig=\(sigCodes) prov=\(provinceCodes) country=\(countryCodes)")
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
        summary.provinceCodes = Set(data?["visitedProvinceCodes"] as? [String] ?? [])
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
