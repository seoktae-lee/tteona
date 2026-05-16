import Foundation
import Combine
import FirebaseFirestore
import CoreLocation

@MainActor
class RoomService: ObservableObject {
    @Published var myRooms: [Room] = []
    @Published var currentRoomMembers: [RoomMember] = []
    @Published var memberLocations: [MemberLocation] = []
    @Published var feedItems: [FeedItem] = []
    @Published var isLoading = false

    private let db = Firestore.firestore()
    private var roomsListener: ListenerRegistration?
    private var locationsListener: ListenerRegistration?
    private var feedListener: ListenerRegistration?
    private var memberFeedListener: ListenerRegistration?

    private struct LocationUploadState {
        var lastSentAt: Date
        var lastSentLocation: CLLocation
    }
    private var locationUploadStates: [String: LocationUploadState] = [:]

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
        
        // 기본 피드 생성 (댓글 작성 보장)
        postFeed(roomId: roomId, type: .tripStart, userId: userId, nickname: nickname, courseId: "system", courseName: "그룹 참여 여행")
        
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

        // 기본 피드 생성 (댓글 작성 보장)
        postFeed(roomId: room.roomId, type: .tripStart, userId: userId, nickname: nickname, courseId: "system", courseName: "그룹 참여 여행")

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

    // MARK: - 동행 세션: 위치 업데이트 (throttled)
    func updateMyLocationThrottled(roomId: String, userId: String, nickname: String, location: CLLocation) {
        let key = "\(roomId)|\(userId)"
        let now = Date()

        // speed: m/s (음수는 invalid)
        let speed = max(0, location.speed)
        let policy: (minInterval: TimeInterval, minDistance: CLLocationDistance) = {
            // 걷기/정지
            if speed < 1.5 { return (10, 50) }
            // 느린 이동(자전거/도심 이동)
            if speed < 6 { return (15, 100) }
            // 차량/빠른 이동
            return (25, 200)
        }()

        if let state = locationUploadStates[key] {
            let elapsed = now.timeIntervalSince(state.lastSentAt)
            let moved = location.distance(from: state.lastSentLocation)

            // 60초에 1번은 무조건 보내서 "너무 오래 멈춘 것처럼" 보이지 않게 한다.
            if elapsed < policy.minInterval || moved < policy.minDistance {
                if elapsed < 60 { return }
            }
        }

        locationUploadStates[key] = LocationUploadState(lastSentAt: now, lastSentLocation: location)
        updateMyLocation(roomId: roomId, userId: userId, nickname: nickname, coordinate: location.coordinate)
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

    // MARK: - 방 나가기 및 자동 파기
    func leaveRoom(roomId: String, userId: String) async throws {
        let roomRef = db.collection("rooms").document(roomId)
        let roomDoc = try await roomRef.getDocument()
        guard let room = try? roomDoc.data(as: Room.self) else { return }

        if room.memberIds.count <= 1 {
            // 마지막 멤버라면 방 전체 데이터 삭제
            try await deleteRoomCompletely(roomId: roomId)
        } else {
            // 다른 멤버가 있다면 나만 멤버 리스트에서 제거
            try await roomRef.updateData([
                "memberIds": FieldValue.arrayRemove([userId])
            ])
            // members 서브컬렉션에서도 삭제
            try await roomRef.collection("members").document(userId).delete()
        }
    }

    private func deleteRoomCompletely(roomId: String) async throws {
        let roomRef = db.collection("rooms").document(roomId)
        
        // 1. 하위 컬렉션 삭제 (locations, members)
        try await deleteCollection(ref: roomRef.collection("locations"))
        try await deleteCollection(ref: roomRef.collection("members"))
        
        // 2. 피드 및 댓글 삭제
        let feedsSnapshot = try await roomRef.collection("feed").getDocuments()
        for feedDoc in feedsSnapshot.documents {
            // 피드 하위의 댓글 삭제
            try await deleteCollection(ref: feedDoc.reference.collection("comments"))
            // 피드 문서 삭제
            try await feedDoc.reference.delete()
        }
        
        // 3. 마지막으로 메인 방 문서 삭제
        try await roomRef.delete()
        print("[Room] Room \(roomId) and all associated data deleted successfully.")
    }

    private func deleteCollection(ref: CollectionReference) async throws {
        let snapshot = try await ref.getDocuments()
        for doc in snapshot.documents {
            try await doc.reference.delete()
        }
    }

    // MARK: - 피드 자동 기록
    func postFeed(roomId: String, type: FeedType, userId: String, nickname: String,
                  courseId: String, courseName: String, placeName: String? = nil,
                  latitude: Double? = nil, longitude: Double? = nil) {
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
        if let latitude { data["latitude"] = latitude }
        if let longitude { data["longitude"] = longitude }
        db.collection("rooms").document(roomId)
            .collection("feed").document(feedId).setData(data)
    }

    // MARK: - 피드 실시간 구독
    func startListeningFeed(roomId: String) {
        feedListener?.remove()
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
    }

    // MARK: - 멤버별 최신 피드 1개씩 가져오기
    func fetchLatestFeedPerMember(roomId: String, memberIds: [String]) async -> [String: FeedItem] {
        var result: [String: FeedItem] = [:]
        await withTaskGroup(of: (String, FeedItem?).self) { group in
            for userId in memberIds {
                group.addTask {
                    let snapshot = try? await self.db.collection("rooms").document(roomId)
                        .collection("feed")
                        .whereField("userId", isEqualTo: userId)
                        .order(by: "createdAt", descending: true)
                        .limit(to: 1)
                        .getDocuments()
                    let item = snapshot?.documents.first.flatMap { try? $0.data(as: FeedItem.self) }
                    return (userId, item)
                }
            }
            for await (userId, item) in group {
                result[userId] = item
            }
        }
        return result
    }

    // MARK: - 오늘 활동 중인 멤버 userId 집합 반환
    func fetchActiveMemberIds(roomId: String) async -> Set<String> {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let snapshot = try? await db.collection("rooms").document(roomId)
            .collection("feed")
            .whereField("createdAt", isGreaterThanOrEqualTo: startOfDay)
            .getDocuments()
        let docs = snapshot?.documents ?? []
        var active: Set<String> = []
        for doc in docs {
            if let userId = doc.data()["userId"] as? String {
                active.insert(userId)
            }
        }
        return active
    }

    // MARK: - 댓글 추가
    func addComment(roomId: String, feedId: String, userId: String, nickname: String, text: String,
                    replyToNickname: String? = nil, replyToText: String? = nil) async throws {
        let commentId = UUID().uuidString
        var data: [String: Any] = [
            "commentId": commentId,
            "userId": userId,
            "nickname": nickname,
            "text": text,
            "createdAt": FieldValue.serverTimestamp()
        ]
        if let rn = replyToNickname { data["replyToNickname"] = rn }
        if let rt = replyToText { data["replyToText"] = rt }

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

    // MARK: - 멤버 피드 실시간 구독
    func startListeningMemberFeed(roomId: String, userId: String, onChange: @escaping ([FeedItem]) -> Void) {
        memberFeedListener?.remove()
        memberFeedListener = db.collection("rooms").document(roomId)
            .collection("feed")
            .whereField("userId", isEqualTo: userId)
            .order(by: "createdAt")
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                let items = docs.compactMap { try? $0.data(as: FeedItem.self) }
                onChange(items)
            }
    }

    func stopListeningMemberFeed() {
        memberFeedListener?.remove()
        memberFeedListener = nil
    }

    func fetchMemberFeedItems(roomId: String, userId: String) async -> [FeedItem] {
        let snapshot = try? await db.collection("rooms").document(roomId)
            .collection("feed")
            .whereField("userId", isEqualTo: userId)
            .order(by: "createdAt")
            .getDocuments()
        return snapshot?.documents.compactMap { try? $0.data(as: FeedItem.self) } ?? []
    }

    func fetchAllCommentsForFeeds(roomId: String, feedIds: [String]) async -> [String: [FeedComment]] {
        var result: [String: [FeedComment]] = [:]
        await withTaskGroup(of: (String, [FeedComment]).self) { group in
            for feedId in feedIds {
                group.addTask {
                    let comments = await self.fetchComments(roomId: roomId, feedId: feedId)
                    return (feedId, comments)
                }
            }
            for await (feedId, comments) in group {
                result[feedId] = comments
            }
        }
        return result
    }

    func addCommentToLatestFeed(roomId: String, userId: String, commenterId: String, commenterNickname: String,
                                text: String, replyToNickname: String? = nil, replyToText: String? = nil) async throws {
        let feeds = await fetchMemberFeedItems(roomId: roomId, userId: userId)
        print("[Comment] feeds count: \(feeds.count), userId: \(userId), roomId: \(roomId)")
        guard let latest = feeds.last else {
            print("[Comment] no feeds found")
            return
        }
        print("[Comment] posting to feedId: \(latest.feedId)")
        try await addComment(roomId: roomId, feedId: latest.feedId,
                             userId: commenterId, nickname: commenterNickname, text: text,
                             replyToNickname: replyToNickname, replyToText: replyToText)
    }

    // MARK: - 읽음 처리
    func markRoomAsRead(roomId: String, userId: String) {
        db.collection("rooms").document(roomId)
            .collection("members").document(userId)
            .setData(["lastReadAt": FieldValue.serverTimestamp()], merge: true)
    }

    func markMemberFeedAsRead(roomId: String, userId: String, memberUserId: String) {
        db.collection("rooms").document(roomId)
            .collection("members").document(userId)
            .setData(["lastReadPerMember.\(memberUserId)": FieldValue.serverTimestamp()], merge: true)
    }

    func fetchMyMemberDoc(roomId: String, userId: String) async -> RoomMember? {
        let doc = try? await db.collection("rooms").document(roomId)
            .collection("members").document(userId).getDocument()
        return try? doc?.data(as: RoomMember.self)
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
