import Foundation
import FirebaseFirestore
import CoreLocation

@MainActor
class RoomService: ObservableObject {
    @Published var myRooms: [Room] = []
    @Published var currentRoomMembers: [RoomMember] = []
    @Published var sharedCourses: [SharedCourse] = []
    @Published var memberLocations: [MemberLocation] = []
    @Published var isLoading = false

    private let db = Firestore.firestore()
    private var roomsListener: ListenerRegistration?
    private var sharedCoursesListener: ListenerRegistration?
    private var locationsListener: ListenerRegistration?

    // MARK: - 방 생성
    func createRoom(name: String, userId: String, nickname: String) async throws -> Room {
        let roomId = UUID().uuidString
        let inviteCode = generateInviteCode()
        let room = Room(
            roomId: roomId,
            name: name,
            inviteCode: inviteCode,
            creatorId: userId,
            memberIds: [userId],
            createdAt: Date()
        )
        try db.collection("rooms").document(roomId).setData(from: room)

        let member = RoomMember(userId: userId, nickname: nickname, joinedAt: Date())
        try db.collection("rooms").document(roomId)
            .collection("members").document(userId).setData(from: member)

        return room
    }

    // MARK: - 초대코드로 방 참여
    func joinRoom(inviteCode: String, userId: String, nickname: String) async throws -> Room {
        let snapshot = try await db.collection("rooms")
            .whereField("inviteCode", isEqualTo: inviteCode.uppercased())
            .getDocuments()

        guard let doc = snapshot.documents.first,
              let room = try? doc.data(as: Room.self) else {
            throw RoomError.roomNotFound
        }

        if room.memberIds.contains(userId) {
            return room
        }

        try await db.collection("rooms").document(room.roomId)
            .updateData(["memberIds": FieldValue.arrayUnion([userId])])

        let member = RoomMember(userId: userId, nickname: nickname, joinedAt: Date())
        try db.collection("rooms").document(room.roomId)
            .collection("members").document(userId).setData(from: member)

        return room
    }

    // MARK: - 내 방 목록 실시간 구독
    func startListeningMyRooms(userId: String) {
        roomsListener?.remove()
        roomsListener = db.collection("rooms")
            .whereField("memberIds", arrayContains: userId)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let docs = snapshot?.documents else { return }
                self.myRooms = docs.compactMap { try? $0.data(as: Room.self) }
                    .sorted { $0.createdAt > $1.createdAt }
            }
    }

    func stopListeningMyRooms() {
        roomsListener?.remove()
        roomsListener = nil
    }

    // MARK: - 방 멤버 조회
    func fetchMembers(roomId: String) async {
        let snapshot = try? await db.collection("rooms").document(roomId)
            .collection("members").getDocuments()
        currentRoomMembers = snapshot?.documents.compactMap { try? $0.data(as: RoomMember.self) } ?? []
    }

    // MARK: - 코스 공유
    func shareCourse(_ course: Course, roomId: String, userId: String, nickname: String) async throws {
        let shared = SharedCourse(
            courseId: course.courseId,
            courseName: course.courseName,
            region: course.region,
            tag: course.tag,
            places: course.places,
            sharedBy: userId,
            sharedByNickname: nickname,
            sharedAt: Date(),
            voteCount: 0,
            votedUserIds: []
        )
        try db.collection("rooms").document(roomId)
            .collection("sharedCourses").document(course.courseId).setData(from: shared)
    }

    // MARK: - 공유 코스 실시간 구독
    func startListeningSharedCourses(roomId: String) {
        sharedCoursesListener?.remove()
        sharedCoursesListener = db.collection("rooms").document(roomId)
            .collection("sharedCourses")
            .order(by: "voteCount", descending: true)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let docs = snapshot?.documents else { return }
                self.sharedCourses = docs.compactMap { try? $0.data(as: SharedCourse.self) }
            }
    }

    func stopListeningSharedCourses() {
        sharedCoursesListener?.remove()
        sharedCoursesListener = nil
    }

    // MARK: - 코스 투표
    func voteCourse(roomId: String, courseId: String, userId: String) async throws {
        let ref = db.collection("rooms").document(roomId)
            .collection("sharedCourses").document(courseId)
        let doc = try await ref.getDocument()
        guard var shared = try? doc.data(as: SharedCourse.self) else { return }

        if shared.votedUserIds.contains(userId) {
            try await ref.updateData([
                "voteCount": FieldValue.increment(Int64(-1)),
                "votedUserIds": FieldValue.arrayRemove([userId])
            ])
        } else {
            try await ref.updateData([
                "voteCount": FieldValue.increment(Int64(1)),
                "votedUserIds": FieldValue.arrayUnion([userId])
            ])
        }
    }

    // MARK: - 동행 세션: 위치 업데이트
    func updateMyLocation(roomId: String, userId: String, nickname: String, coordinate: CLLocationCoordinate2D) {
        let data: [String: Any] = [
            "userId": userId,
            "nickname": nickname,
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        db.collection("rooms").document(roomId)
            .collection("locations").document(userId).setData(data, merge: true)
    }

    func stopSharingLocation(roomId: String, userId: String) {
        db.collection("rooms").document(roomId)
            .collection("locations").document(userId).delete()
    }

    // MARK: - 동행 세션: 멤버 위치 실시간 구독
    func startListeningLocations(roomId: String, myUserId: String) {
        locationsListener?.remove()
        locationsListener = db.collection("rooms").document(roomId)
            .collection("locations")
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let docs = snapshot?.documents else { return }
                self.memberLocations = docs
                    .compactMap { try? $0.data(as: MemberLocation.self) }
                    .filter { $0.userId != myUserId }
            }
    }

    func stopListeningLocations() {
        locationsListener?.remove()
        locationsListener = nil
    }

    // MARK: - 방 나가기
    func leaveRoom(roomId: String, userId: String) async throws {
        try await db.collection("rooms").document(roomId)
            .updateData(["memberIds": FieldValue.arrayRemove([userId])])
        try await db.collection("rooms").document(roomId)
            .collection("members").document(userId).delete()
        try await db.collection("rooms").document(roomId)
            .collection("locations").document(userId).delete()
    }

    // MARK: - Helper
    private func generateInviteCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }
}

enum RoomError: LocalizedError {
    case roomNotFound

    var errorDescription: String? {
        switch self {
        case .roomNotFound: return "해당 초대 코드의 방을 찾을 수 없어요."
        }
    }
}
