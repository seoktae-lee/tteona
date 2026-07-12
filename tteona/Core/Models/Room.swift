import Foundation
import FirebaseFirestore

struct Room: Identifiable, Codable, Hashable {
    @DocumentID var id: String?
    var roomId: String
    var name: String
    var inviteCode: String
    var creatorId: String
    var memberIds: [String]
    var createdAt: Date
    var imageUrl: String?   // 방 대표 이미지 (전 멤버 공통) — WAS 업로드 후 서버가 세팅

    enum CodingKeys: String, CodingKey {
        case id, roomId, name, inviteCode, creatorId, memberIds, createdAt, imageUrl
    }
}

struct RoomMember: Identifiable, Codable {
    @DocumentID var id: String?
    var userId: String
    var nickname: String
    var joinedAt: Date
    var lastReadAt: Date?
    var lastReadPerMember: [String: Date]?

    enum CodingKeys: String, CodingKey {
        case id, userId, nickname, joinedAt, lastReadAt, lastReadPerMember
    }
}

struct MemberLocation: Identifiable, Codable {
    @DocumentID var id: String?
    var userId: String
    var nickname: String
    var latitude: Double
    var longitude: Double
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, userId, nickname, latitude, longitude, updatedAt
    }
}

enum FeedType: String, Codable {
    case tripStart = "tripStart"
    case tripEnd = "tripEnd"
    case arrival = "arrival"
    case photo = "photo"
    case freeTripStart = "freeTripStart"
    case freeCapture = "freeCapture"
    case freeTripEnd = "freeTripEnd"
}

struct FeedItem: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var feedId: String
    var type: FeedType
    var userId: String
    var nickname: String
    var courseId: String
    var courseName: String
    var placeName: String?
    var imageUrl: String?
    var latitude: Double?
    var longitude: Double?
    var commentCount: Int
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, feedId, type, userId, nickname
        case courseId, courseName, placeName, imageUrl
        case latitude, longitude
        case commentCount, createdAt
    }
}

struct FeedComment: Identifiable, Codable {
    @DocumentID var id: String?
    var commentId: String
    var userId: String
    var nickname: String
    var text: String
    var replyToNickname: String?
    var replyToText: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, commentId, userId, nickname, text
        case replyToNickname, replyToText, createdAt
    }
}
