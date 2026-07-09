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

    // MARK: 집계 (기록·백필 공용)

    /// 코스의 장소별 지역 집계 결과 — "가장 많이 머문 지역"이 앞에 오도록 체류순 정렬.
    struct Aggregated {
        let sigCodes: [String]
        let provinceCodes: [String]
        let countryCodes: [String]
        let regionNames: [String]
        let points: [FootprintPoint]
    }

    /// 코스의 장소들을 지역으로 판정·집계한다. 지역이 하나도 안 잡히면 nil.
    /// 첫 장소가 아니라 체류 빈도가 기준이라 잠깐 스친 환승지가 대표로 뽑히지 않는다.
    /// 한국은 시군구, 해외는 주/도(admin-1) 단위.
    private func aggregate(course: Course) async -> Aggregated? {
        let places = course.places
        let resolved = await Task.detached(priority: .utility) {
            FootprintAtlas.shared.ensureLoaded()
            return places.map { FootprintAtlas.shared.resolve(lat: $0.latitude, lng: $0.longitude) }
        }.value

        var sigCount: [String: Int] = [:]
        var sigName: [String: String] = [:]
        var provCount: [String: Int] = [:]
        var provName: [String: String] = [:]
        var countryCount: [String: Int] = [:]
        for region in resolved {
            if let sig = region.sig {
                sigCount[sig.code, default: 0] += 1
                sigName[sig.code] = sig.name
            } else if let province = region.province {
                provCount[province.code, default: 0] += 1
                provName[province.code] = province.name
            }
            if let country = region.countryCode {
                countryCount[country, default: 0] += 1
            }
        }
        let sigCodes = sigCount.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let provinceCodes = provCount.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let countryCodes = countryCount.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        guard !sigCodes.isEmpty || !provinceCodes.isEmpty else { return nil }

        var regionNames = sigCodes.compactMap { sigName[$0] }
        regionNames += provinceCodes.compactMap { provName[$0] }

        return Aggregated(
            sigCodes: sigCodes,
            provinceCodes: provinceCodes,
            countryCodes: countryCodes,
            regionNames: regionNames,
            points: places.sorted { $0.order < $1.order }
                .map { FootprintPoint(lat: $0.latitude, lng: $0.longitude) }
        )
    }

    // MARK: 기록 (브이로그 생성 성공 시)

    /// 코스의 장소들을 지역으로 판정해 발자취를 적재한다. 실패해도 앱 흐름을 막지 않는다(fire-and-forget).
    func record(course: Course, sessionId: String, userId: String) async {
        guard let agg = await aggregate(course: course) else {
            print("[Footprint] no region resolved — skip")
            return
        }

        let record = FootprintRecord(
            courseId: course.courseId,
            courseName: course.courseName,
            date: Date(),
            placeCount: course.places.count,
            sigCodes: agg.sigCodes,
            provinceCodes: agg.provinceCodes,
            countryCodes: agg.countryCodes,
            regionNames: agg.regionNames,
            points: agg.points
        )

        do {
            // 새로 칠해지는 지역 계산 (하이라이트 연출용) — 기존 요약과 비교
            let newCodes = Set(agg.sigCodes).subtracting(mySummary.sigCodes)
                .union(Set(agg.provinceCodes).subtracting(mySummary.provinceCodes))

            // 세션ID를 문서ID로 → 같은 세션 재생성 시 덮어쓰기(중복 방지)
            try db.collection("users").document(userId)
                .collection("footprints").document(sessionId)
                .setData(from: record)
            try await db.collection("users").document(userId).updateData([
                "visitedSigCodes": FieldValue.arrayUnion(agg.sigCodes),
                "visitedProvinceCodes": FieldValue.arrayUnion(agg.provinceCodes),
                "visitedCountryCodes": FieldValue.arrayUnion(agg.countryCodes)
            ])

            mySummary.sigCodes.formUnion(agg.sigCodes)
            mySummary.provinceCodes.formUnion(agg.provinceCodes)
            mySummary.countryCodes.formUnion(agg.countryCodes)
            if !newCodes.isEmpty {
                lastNewCodes = newCodes
                // 대표 신규 지역 = 체류순 정렬(시군구 우선)에서 처음으로 등장하는 새 지역
                lastPrimaryNewCode = (agg.sigCodes + agg.provinceCodes).first { newCodes.contains($0) }
            }
            print("[Footprint] recorded sig=\(agg.sigCodes) prov=\(agg.provinceCodes) country=\(agg.countryCodes)")
        } catch {
            print("[Footprint] record failed:", error.localizedDescription)
        }
    }

    // MARK: 백필 (과거 코스 소급 — Phase 1, 유저당 1회)

    /// 발자취 기록 훅이 생기기 전에 만든 코스들을 발자취로 소급 반영한다.
    /// 내가 만든 코스는 실제 촬영 세션에서 저장된 것이므로 "실제 방문"으로 간주.
    /// 문서 ID `course_{courseId}`로 멱등 — 부분 실패 시 다음 진입에서 재시도해도 중복 없음.
    func backfillFromMyCourses(userId: String) async {
        let userRef = db.collection("users").document(userId)
        let doc = try? await userRef.getDocument()
        if (doc?.data()?["footprintBackfillV1"] as? Bool) == true { return }

        let courses = await fetchCourses(authorId: userId)
        guard !courses.isEmpty else {
            // 코스가 없어도 플래그를 세팅해 재실행을 막는다
            try? await userRef.updateData(["footprintBackfillV1": true])
            return
        }

        var allSig = Set<String>(), allProv = Set<String>(), allCountry = Set<String>()
        var wroteAny = false
        var allSucceeded = true

        for course in courses {
            guard let agg = await aggregate(course: course) else { continue }
            let record = FootprintRecord(
                courseId: course.courseId,
                courseName: course.courseName,
                date: course.createdAt,   // 여행 시점 보존 → 타임라인 순서 정확
                placeCount: course.places.count,
                sigCodes: agg.sigCodes,
                provinceCodes: agg.provinceCodes,
                countryCodes: agg.countryCodes,
                regionNames: agg.regionNames,
                points: agg.points
            )
            do {
                try userRef.collection("footprints")
                    .document("course_\(course.courseId)")
                    .setData(from: record)
                allSig.formUnion(agg.sigCodes)
                allProv.formUnion(agg.provinceCodes)
                allCountry.formUnion(agg.countryCodes)
                wroteAny = true
            } catch {
                allSucceeded = false
                print("[Footprint] backfill doc failed:", error.localizedDescription)
            }
        }

        // 방문 지역 합산 반영 (하이라이트 연출은 발동하지 않음 — 수십 곳 펄스 방지)
        var fields: [String: Any] = [:]
        if wroteAny {
            fields["visitedSigCodes"] = FieldValue.arrayUnion(Array(allSig))
            fields["visitedProvinceCodes"] = FieldValue.arrayUnion(Array(allProv))
            fields["visitedCountryCodes"] = FieldValue.arrayUnion(Array(allCountry))
        }
        // 모든 쓰기가 성공했을 때만 플래그 세팅 → 부분 실패는 다음 진입에 재시도(멱등)
        if allSucceeded { fields["footprintBackfillV1"] = true }
        if !fields.isEmpty { try? await userRef.updateData(fields) }

        if wroteAny {
            mySummary.sigCodes.formUnion(allSig)
            mySummary.provinceCodes.formUnion(allProv)
            mySummary.countryCodes.formUnion(allCountry)
        }
        print("[Footprint] backfilled courses=\(courses.count) wrote=\(wroteAny) complete=\(allSucceeded)")
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
