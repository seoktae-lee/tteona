import Foundation
import Combine
import FirebaseFirestore

@MainActor
class RoomService: ObservableObject {
    @Published var myRooms: [Room] = []
    @Published var unreadRoomIds: Set<String> = []
    @Published var currentRoomMembers: [RoomMember] = []
    @Published var feedItems: [FeedItem] = []
    @Published var isLoading = false

    private let db = Firestore.firestore()
    private var roomsListener: ListenerRegistration?
    private var feedListener: ListenerRegistration?
    private var memberFeedListener: ListenerRegistration?

    /// 차단한 유저의 피드·댓글을 숨기기 위한 목록 — MainTabView가 유저 로드/차단 변경 시 갱신
    var blockedUserIds: Set<String> = []

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
        postFeed(roomId: roomId, type: .tripStart, userId: userId, nickname: nickname, courseId: "system", courseName: L("room.groupTrip"))
        
        return room
    }

    // MARK: - 초대코드로 방 참여 (서버 경유)
    // Firestore rules가 "멤버만 읽기"라 초대코드 검색은 서버 Admin SDK가 수행한다.
    func joinRoom(inviteCode: String, userId: String, nickname: String) async throws -> Room {
        guard let url = URL(string: "https://tteona.kr/api/rooms/join") else {
            throw RoomError.roomNotFound
        }
        let req = await APIAuth.request(url: url, method: "POST", jsonBody: [
            "inviteCode": inviteCode.uppercased(),
            "userId": userId,
            "nickname": nickname,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 { throw RoomError.roomNotFound }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roomId = json["roomId"] as? String else {
            throw RoomError.joinFailed
        }

        let room = Room(
            roomId: roomId,
            name: json["name"] as? String ?? L("room.defaultName"),
            inviteCode: json["inviteCode"] as? String ?? inviteCode.uppercased(),
            creatorId: json["creatorId"] as? String ?? "",
            memberIds: json["memberIds"] as? [String] ?? [userId],
            createdAt: Date()
        )

        // 기본 피드 생성 (댓글 작성 보장)
        postFeed(roomId: room.roomId, type: .tripStart, userId: userId, nickname: nickname, courseId: "system", courseName: L("room.groupTrip"))

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

    // 참고: 실시간 위치 공유는 LocationSocketService(WebSocket)가 담당한다.
    // 과거 Firestore 기반 위치 공유 경로(updateMyLocation/startListeningLocations 등)는
    // 어디서도 호출되지 않아 제거했다.

    // MARK: - 방 나가기 및 자동 파기 (서버 경유)
    // 마지막 멤버의 방 정리는 다른 멤버가 남긴 피드/문서 삭제 권한이 클라이언트에
    // 없으므로 서버 Admin SDK가 recursiveDelete로 처리한다. 서버 실패 시
    // 멤버 제거만 클라이언트에서 폴백 수행.
    func leaveRoom(roomId: String, userId: String) async throws {
        if let url = URL(string: "https://tteona.kr/api/rooms/\(roomId)/leave") {
            let req = await APIAuth.request(url: url, method: "POST", jsonBody: ["userId": userId])
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
        }
        // 폴백: 멤버 목록에서 나만 제거 (빈 방 정리는 서버 복구 후 재시도 가능)
        let roomRef = db.collection("rooms").document(roomId)
        try await roomRef.updateData([
            "memberIds": FieldValue.arrayRemove([userId])
        ])
        try? await roomRef.collection("members").document(userId).delete()
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
                    .filter { !self.blockedUserIds.contains($0.userId) }
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
        // 콘텐츠 모더레이션 (서버 검사, 네트워크 실패 시 통과)
        guard await StatsService.shared.isTextAllowed(text) else {
            throw RoomError.inappropriateContent
        }
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
        return (snapshot?.documents.compactMap { try? $0.data(as: FeedComment.self) } ?? [])
            .filter { !blockedUserIds.contains($0.userId) }
    }

    // MARK: - 멤버 피드 실시간 구독
    func startListeningMemberFeed(roomId: String, userId: String, onChange: @escaping ([FeedItem]) -> Void) {
        memberFeedListener?.remove()
        memberFeedListener = db.collection("rooms").document(roomId)
            .collection("feed")
            .whereField("userId", isEqualTo: userId)
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                let blocked = self?.blockedUserIds ?? []
                let items = docs.compactMap { try? $0.data(as: FeedItem.self) }
                    .filter { !blocked.contains($0.userId) }
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
        dlog("[Comment] feeds count: \(feeds.count), userId: \(userId), roomId: \(roomId)")
        guard let latest = feeds.last else {
            dlog("[Comment] no feeds found")
            return
        }
        dlog("[Comment] posting to feedId: \(latest.feedId)")
        try await addComment(roomId: roomId, feedId: latest.feedId,
                             userId: commenterId, nickname: commenterNickname, text: text,
                             replyToNickname: replyToNickname, replyToText: replyToText)
    }

    // MARK: - 읽음 처리
    func markRoomAsRead(roomId: String, userId: String) {
        unreadRoomIds.remove(roomId)
        db.collection("rooms").document(roomId)
            .collection("members").document(userId)
            .setData(["lastReadAt": FieldValue.serverTimestamp()], merge: true)
    }

    // 안읽음 방 집합 갱신 — 서버가 한 번에 집계해 돌려준다(방×멤버 팬아웃 제거).
    // 서버 실패 시에만 기존 클라이언트 계산으로 폴백해 기능 연속성을 지킨다.
    func refreshUnreadStatus(userId: String) async {
        if let url = URL(string: "https://tteona.kr/api/rooms/unread"),
           let (data, resp) = try? await APIAuth.get(url),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ids = json["unreadRoomIds"] as? [String] {
            self.unreadRoomIds = Set(ids)
            return
        }
        await refreshUnreadStatusLocal(userId: userId)
    }

    // 폴백: 클라이언트에서 방별로 직접 계산 (서버 미배포/오류 대비)
    private func refreshUnreadStatusLocal(userId: String) async {
        let rooms = myRooms
        var unread: Set<String> = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for room in rooms {
                group.addTask {
                    async let memberDoc = self.fetchMyMemberDoc(roomId: room.roomId, userId: userId)
                    async let latestFeeds = self.fetchLatestFeedPerMember(roomId: room.roomId, memberIds: room.memberIds)
                    guard let latestDate = await latestFeeds.values.map(\.createdAt).max() else {
                        return (room.roomId, false)
                    }
                    guard let readAt = await memberDoc?.lastReadAt else { return (room.roomId, true) }
                    return (room.roomId, latestDate > readAt)
                }
            }
            for await (roomId, isUnread) in group where isUnread {
                unread.insert(roomId)
            }
        }
        let result = unread
        await MainActor.run { self.unreadRoomIds = result }
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
    case joinFailed
    case inappropriateContent

    var errorDescription: String? {
        switch self {
        case .roomNotFound: return L("room.error.notFound")
        case .joinFailed: return L("room.error.joinFailed")
        case .inappropriateContent: return L("room.error.inappropriate")
        }
    }
}
