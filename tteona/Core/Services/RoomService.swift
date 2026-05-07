import Foundation
import Combine
import FirebaseFirestore
import CoreLocation

@MainActor
class RoomService: ObservableObject {
    @Published var myRooms: [Room] = []
    @Published var currentRoomMembers: [RoomMember] = []
    @Published var sharedCourses: [SharedCourse] = []
    @Published var memberLocations: [MemberLocation] = []
    @Published var feedItems: [FeedItem] = []
    @Published var isLoading = false

    private let db = Firestore.firestore()
    private var roomsListener: ListenerRegistration?
    private var sharedCoursesListener: ListenerRegistration?
    private var locationsListener: ListenerRegistration?
    private var feedListener: ListenerRegistration?

    // MARK: - 방 생성
    func createRoom(name: String, userId: String, nickname: String) async throws -> Room {
        let roomId = UUID().uuidString
        let inviteCode = generateInviteCode()
        let data: [String: Any] = [
            "roomId": roomId,
            "name": name,
            "inviteCode": inviteCode,
            "creatorId": userId,
            "memberIds": [userId],
            "createdAt": FieldValue.serverTimestamp()
        ]
        try await db.collection("rooms").document(roomId).setData(data)

        let memberData: [String: Any] = [
            "userId": userId,
            "nickname": nickname,
            "joinedAt": FieldValue.serverTimestamp()
        ]
        try await db.collection("rooms").document(roomId)
            .collection("members").document(userId).setData(memberData)

        let room = Room(
            roomId: roomId,
            name: name,
            inviteCode: inviteCode,
            creatorId: userId,
            memberIds: [userId],
            createdAt: Date()
        )
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

        let memberData: [String: Any] = [
            "userId": userId,
            "nickname": nickname,
            "joinedAt": FieldValue.serverTimestamp()
        ]
        try await db.collection("rooms").document(room.roomId)
            .collection("members").document(userId).setData(memberData)

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
        let placesData = course.places.map { place -> [String: Any] in
            ["order": place.order, "placeName": place.placeName,
             "latitude": place.latitude, "longitude": place.longitude]
        }
        let data: [String: Any] = [
            "courseId": course.courseId,
            "courseName": course.courseName,
            "region": course.region,
            "tag": course.tag.rawValue,
            "places": placesData,
            "sharedBy": userId,
            "sharedByNickname": nickname,
            "sharedAt": FieldValue.serverTimestamp(),
            "voteCount": 0,
            "votedUserIds": []
        ]
        try await db.collection("rooms").document(roomId)
            .collection("sharedCourses").document(course.courseId).setData(data)
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

    // MARK: - 피드 자동 기록
    func postFeed(roomId: String, type: FeedType, userId: String, nickname: String,
                  courseId: String, courseName: String, placeName: String? = nil) {
        let feedId = UUID().uuidString
        var data: [String: Any] = [
            "feedId": feedId,
            "type": type.rawValue,
            "userId": userId,
            "nickname": nickname,
            "courseId": courseId,
            "courseName": courseName,
            "commentCount": 0,
            "createdAt": FieldValue.serverTimestamp()
        ]
        if let placeName { data["placeName"] = placeName }
        db.collection("rooms").document(roomId)
            .collection("feed").document(feedId).setData(data)
    }

    // MARK: - 피드 실시간 구독
    func startListeningFeed(roomId: String) {
        feedListener?.remove()
        feedItems = []
        feedListener = db.collection("rooms").document(roomId)
            .collection("feed")
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let docs = snapshot?.documents else { return }
                self.feedItems = docs.compactMap { try? $0.data(as: FeedItem.self) }
            }
    }

    func stopListeningFeed() {
        feedListener?.remove()
        feedListener = nil
        feedItems = []
    }

    // MARK: - 댓글 추가
    func addComment(roomId: String, feedId: String, userId: String, nickname: String, text: String) async throws {
        let commentId = UUID().uuidString
        let data: [String: Any] = [
            "commentId": commentId,
            "userId": userId,
            "nickname": nickname,
            "text": text,
            "createdAt": FieldValue.serverTimestamp()
        ]
        try await db.collection("rooms").document(roomId)
            .collection("feed").document(feedId)
            .collection("comments").document(commentId).setData(data)
        try await db.collection("rooms").document(roomId)
            .collection("feed").document(feedId)
            .updateData(["commentCount": FieldValue.increment(Int64(1))])

        // 피드 작성자에게 댓글 알림
        let feedDoc = try? await db.collection("rooms").document(roomId)
            .collection("feed").document(feedId).getDocument()
        if let feedAuthorId = feedDoc?.data()?["userId"] as? String {
            await FCMService.shared.requestCommentNotification(
                senderUserId: userId,
                senderNickname: nickname,
                feedAuthorUserId: feedAuthorId,
                roomId: roomId,
                commentText: text
            )
        }
    }

    // MARK: - 댓글 목록 조회
    func fetchComments(roomId: String, feedId: String) async -> [FeedComment] {
        let snapshot = try? await db.collection("rooms").document(roomId)
            .collection("feed").document(feedId)
            .collection("comments")
            .order(by: "createdAt")
            .getDocuments()
        return snapshot?.documents.compactMap { try? $0.data(as: FeedComment.self) } ?? []
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
