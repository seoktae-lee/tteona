import Foundation
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

    func fetchCourses() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let snapshot = try await db.collection("courses")
                .order(by: "likeCount", descending: true)
                .getDocuments()
            self.courses = snapshot.documents.compactMap { doc in
                try? doc.data(as: Course.self)
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func saveCourse(_ course: Course) async throws {
        try db.collection("courses").document(course.courseId).setData(from: course)
        courses.insert(course, at: 0)
    }

    func deleteCourse(_ course: Course) async throws {
        try await db.collection("courses").document(course.courseId).delete()
        courses.removeAll { $0.courseId == course.courseId }
        likedCourseIds.remove(course.courseId)
    }

    func toggleLike(courseId: String, userId: String) async throws {
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
        } catch {
            // Rollback local state on failure
            likedCourseIds = previousLiked
            courses = previousCourses
            errorMessage = "좋아요 처리에 실패했습니다. 네트워크 상태를 확인하고 다시 시도해주세요."
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
