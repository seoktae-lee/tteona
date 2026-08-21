import Foundation
import CoreLocation
import Combine
import FirebaseFirestore

@MainActor
class CourseService: ObservableObject {
    @Published var courses: [Course] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var likedCourseIds: Set<String> = []

    private let db = Firestore.firestore()
    private var likedCourseIdsFetched = false

    /// 마지막으로 서버에서 받아온 시각 — 이 안에서는 다시 부르지 않는다
    private var lastFetchedAt: Date?
    private static let cacheTTL: TimeInterval = 5 * 60

    /// 지도·탐색 공용 코스 목록.
    ///
    /// 같은 데이터를 여러 화면이 각자 부르고(지도/탐색), 뷰가 재생성될 때마다 또 불러
    /// 진입할 때 300건을 두 번씩 받아오고 있었다. 최근에 받아둔 게 있으면 건너뛴다.
    /// 당겨서 새로고침처럼 최신본이 꼭 필요할 때만 `force: true`로 강제한다.
    func fetchCourses(blockedUserIds: [String] = [], force: Bool = false) async {
        if !force, !courses.isEmpty,
           let at = lastFetchedAt, Date().timeIntervalSince(at) < Self.cacheTTL {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 처음 진입이면 로컬 캐시로 먼저 그린다 — 서버 응답까지 빈 지도를 보여주지 않는다.
        // (Firestore iOS SDK는 기본적으로 디스크 캐시를 유지한다)
        if courses.isEmpty {
            var cached: [QuerySnapshot] = []
            for query in Self.popularAndCuratedQueries(db) {
                if let snapshot = try? await query.getDocuments(source: .cache) {
                    cached.append(snapshot)
                }
            }
            if cached.contains(where: { !$0.isEmpty }) {
                self.courses = Self.merge(cached, blockedUserIds: blockedUserIds)
            }
        }

        do {
            var snapshots: [QuerySnapshot] = []
            for query in Self.popularAndCuratedQueries(db) {
                snapshots.append(try await query.getDocuments())
            }
            self.courses = Self.merge(snapshots, blockedUserIds: blockedUserIds)
            self.lastFetchedAt = Date()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// 지도·탐색의 기본 로드는 **두 쿼리**다. 하나로 합칠 수 없다.
    ///
    /// 1. 인기순 상위 300 — 코스가 수천 개로 늘어도 진입이 느려지거나 읽기 비용이
    ///    폭증하지 않게 둔 상한. 지도 특성상 수백 개 이상 핀은 사람이 구분하지 못한다.
    /// 2. 큐레이션 전량 — **큐레이션 코스는 좋아요가 0에서 시작하므로 1번에 절대 들지
    ///    못한다.** 이 쿼리가 없으면 코스를 넣어도 지도에 영원히 안 뜬다. 수백 개
    ///    규모라 상한 500이면 충분하고, 정렬을 걸지 않아 복합 인덱스도 필요 없다.
    ///
    /// (특정 지역의 비인기 UGC 코스는 fetchCoursesInRegion / fetchCoursesNear로 보완)
    private static func popularAndCuratedQueries(_ db: Firestore) -> [Query] {
        [
            db.collection("courses").order(by: "likeCount", descending: true).limit(to: 300),
            db.collection("courses").whereField("curated", isEqualTo: true).limit(to: 500),
        ]
    }

    /// 두 쿼리 결과를 courseId 기준으로 합치고 차단 유저를 걸러낸다.
    /// 큐레이션 코스가 인기 상위 300에 들면 양쪽에 나타나므로 중복 제거가 필수다.
    private static func merge(_ snapshots: [QuerySnapshot], blockedUserIds: [String]) -> [Course] {
        var seen = Set<String>()
        var result: [Course] = []
        for snapshot in snapshots {
            for doc in snapshot.documents {
                guard let course = try? doc.data(as: Course.self),
                      !blockedUserIds.contains(course.authorId),
                      seen.insert(course.courseId).inserted else { continue }
                result.append(course)
            }
        }
        return result
    }

    /// 지역 검색 보완 — 인기 상위 300에 들지 못한 그 지역 코스를 별도로 불러와 병합한다.
    /// (기본 로드는 인기순 상한이라, 특정 지역을 검색하면 그 지역 코스가 누락될 수 있다.)
    /// region 필드 prefix 매칭(단일 필드 인덱스는 자동 생성됨).
    func fetchCoursesInRegion(_ query: String, blockedUserIds: [String] = []) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let snapshot = try? await db.collection("courses")
            .whereField("region", isGreaterThanOrEqualTo: q)
            .whereField("region", isLessThan: q + "\u{f8ff}")
            .limit(to: 100)
            .getDocuments()
        let fetched = snapshot?.documents.compactMap { try? $0.data(as: Course.self) } ?? []
        let existingIds = Set(courses.map(\.courseId))
        let merged = fetched.filter { !existingIds.contains($0.courseId) && !blockedUserIds.contains($0.authorId) }
        guard !merged.isEmpty else { return }
        courses.append(contentsOf: merged)
    }

    /// 좌표 주변 코스를 불러와 병합한다. 지도에서 장소를 검색해 이동했을 때,
    /// 인기 상위 300에 못 든 그 동네 코스가 안 보이는 것을 메운다.
    ///
    /// Firestore에 지리 인덱스가 없다. 대신 `region`이 코스 생성 시
    /// 대표 장소의 위도로 만들어진다("37.4°N") — 사실상 유일한 좌표 단서라 이걸 쓴다.
    /// 밴드는 0.1° 단위(약 11km)라 경계에서 놓치지 않도록 위아래 한 칸씩 같이 본다.
    /// 위도 밴드는 경도를 가리지 못하므로, 받아온 뒤 실제 거리로 한 번 더 거른다.
    func fetchCoursesNear(latitude: Double, longitude: Double,
                          radiusKm: Double = 60, blockedUserIds: [String] = []) async {
        let bands = [-0.1, 0.0, 0.1].map { String(format: "%.1f°N", latitude + $0) }
        let origin = CLLocation(latitude: latitude, longitude: longitude)

        var fetched: [Course] = []
        for band in bands {
            // UGC 코스: region 자체가 위도 밴드다
            let byRegion = try? await db.collection("courses")
                .whereField("region", isEqualTo: band)
                .limit(to: 100)
                .getDocuments()
            fetched += byRegion?.documents.compactMap { try? $0.data(as: Course.self) } ?? []

            // 큐레이션 코스: region이 읽히는 지역명("서울")이라 별도 latBand로 찾는다.
            // 이게 없으면 전국 큐레이션 코스가 초기 로드 상한(500) 밖으로 밀리는 순간
            // 그 지역으로 지도를 옮겨도 영영 나타나지 않는다.
            let byBand = try? await db.collection("courses")
                .whereField("latBand", isEqualTo: band)
                .limit(to: 100)
                .getDocuments()
            fetched += byBand?.documents.compactMap { try? $0.data(as: Course.self) } ?? []
        }

        let existingIds = Set(courses.map(\.courseId))
        let merged = fetched.filter { course in
            guard !existingIds.contains(course.courseId),
                  !blockedUserIds.contains(course.authorId),
                  let main = course.mainPlace else { return false }
            let d = origin.distance(from: CLLocation(latitude: main.latitude, longitude: main.longitude))
            return d <= radiusKm * 1000
        }
        guard !merged.isEmpty else { return }
        courses.append(contentsOf: merged)
    }

    func saveCourse(_ course: Course) async throws {
        try db.collection("courses").document(course.courseId).setData(from: course)
        courses.insert(course, at: 0)
        Task { await StatsService.shared.postEvent(.courseCreated, userId: course.authorId) }
    }

    /// 코스 이름·태그 수정 (작성자만 — Firestore 규칙이 작성자 전체수정 허용).
    func updateCourseInfo(courseId: String, name: String, tag: CourseTag) async throws {
        try await db.collection("courses").document(courseId).updateData([
            "courseName": name,
            "tag": tag.rawValue
        ])
        if let idx = courses.firstIndex(where: { $0.courseId == courseId }) {
            courses[idx].courseName = name
            courses[idx].tag = tag
        }
    }

    func deleteCourse(_ course: Course) async throws {
        try await db.collection("courses").document(course.courseId).delete()
        courses.removeAll { $0.courseId == course.courseId }
        likedCourseIds.remove(course.courseId)
    }

    func toggleLike(courseId: String, userId: String, likerNickname: String = "") async throws {
        errorMessage = nil

        let alreadyLiked = likedCourseIds.contains(courseId)
        let userRef = db.collection("users").document(userId)
        let courseRef = db.collection("courses").document(courseId)

        // Optimistic UI update
        let previousLiked = likedCourseIds
        let previousCourses = courses

        if alreadyLiked {
            likedCourseIds.remove(courseId)
            if let idx = courses.firstIndex(where: { $0.courseId == courseId }) {
                courses[idx].likeCount = max(0, courses[idx].likeCount - 1)
            }
        } else {
            likedCourseIds.insert(courseId)
            if let idx = courses.firstIndex(where: { $0.courseId == courseId }) {
                courses[idx].likeCount += 1
            }
        }

        do {
            let batch = db.batch()
            if alreadyLiked {
                batch.setData(
                    ["likedCourseIds": FieldValue.arrayRemove([courseId])],
                    forDocument: userRef,
                    merge: true
                )
                batch.updateData(["likeCount": FieldValue.increment(Int64(-1))], forDocument: courseRef)
            } else {
                batch.setData(
                    ["likedCourseIds": FieldValue.arrayUnion([courseId])],
                    forDocument: userRef,
                    merge: true
                )
                batch.updateData(["likeCount": FieldValue.increment(Int64(1))], forDocument: courseRef)
            }
            try await batch.commit()

            // 좋아요 시 코스 작성자에게 APNs 알림 (본인 제외)
            if !alreadyLiked,
               let course = courses.first(where: { $0.courseId == courseId }),
               course.authorId != userId {
                Task {
                    await PushService.shared.notifyCourseLiked(
                        courseOwnerId: course.authorId,
                        likerNickname: likerNickname,
                        courseName: course.courseName,
                        courseId: course.courseId
                    )
                }
            }
            if !alreadyLiked {
                Task { await StatsService.shared.postEvent(.courseLiked, userId: userId) }
            }
        } catch {
            // Rollback local state on failure
            likedCourseIds = previousLiked
            courses = previousCourses
            errorMessage = L("course.likeFailed")
            throw error
        }
    }

    func fetchCourse(by courseId: String) async throws -> Course? {
        if let cached = courses.first(where: { $0.courseId == courseId }) {
            return cached
        }
        let doc = try await db.collection("courses").document(courseId).getDocument()
        return try? doc.data(as: Course.self)
    }

    func fetchLikedCourseIds(userId: String) async {
        guard !likedCourseIdsFetched else { return }
        let doc = try? await db.collection("users").document(userId).getDocument()
        let ids = doc?.data()?["likedCourseIds"] as? [String] ?? []
        likedCourseIds = Set(ids)
        likedCourseIdsFetched = true
    }

    func clearUserData() {
        likedCourseIds = []
        likedCourseIdsFetched = false
    }
}

// MARK: - Mock Data (Preview용)
extension Course {
    static let mockCourses: [Course] = [
        Course(
            courseId: "mock-1",
            authorId: "user-1",
            courseName: "서울 감성 데이트 코스",
            tag: .couple,
            region: "서울",
            likeCount: 142,
            createdAt: Date(),
            places: [
                Place(order: 1, placeName: "경복궁", latitude: 37.5796, longitude: 126.9770),
                Place(order: 2, placeName: "북촌 한옥마을", latitude: 37.5826, longitude: 126.9830),
                Place(order: 3, placeName: "광화문 광장", latitude: 37.5757, longitude: 126.9769)
            ]
        ),
        Course(
            courseId: "mock-2",
            authorId: "user-2",
            courseName: "제주 우도 친구 여행",
            tag: .friends,
            region: "제주",
            likeCount: 98,
            createdAt: Date(),
            places: [
                Place(order: 1, placeName: "성산일출봉", latitude: 33.4586, longitude: 126.9429),
                Place(order: 2, placeName: "우도", latitude: 33.5019, longitude: 126.9514)
            ]
        ),
        Course(
            courseId: "mock-3",
            authorId: "user-3",
            courseName: "부산 해운대 힐링 코스",
            tag: .solo,
            region: "부산",
            likeCount: 76,
            createdAt: Date(),
            places: [
                Place(order: 1, placeName: "해운대 해수욕장", latitude: 35.1587, longitude: 129.1603),
                Place(order: 2, placeName: "광안리 해수욕장", latitude: 35.1533, longitude: 129.1185),
                Place(order: 3, placeName: "감천 문화마을", latitude: 35.0975, longitude: 129.0104)
            ]
        )
    ]

    init(courseId: String, authorId: String, courseName: String, tag: CourseTag,
         region: String, likeCount: Int, createdAt: Date, places: [Place]) {
        self.courseId = courseId
        self.authorId = authorId
        self.courseName = courseName
        self.tag = tag
        self.region = region
        self.likeCount = likeCount
        self.createdAt = createdAt
        self.places = places
    }
}
