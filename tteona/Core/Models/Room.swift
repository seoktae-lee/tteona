import Foundation
import FirebaseFirestore

struct Room: Identifiable, Codable {
    @DocumentID var id: String?
    var roomId: String
    var name: String
    var inviteCode: String
    var creatorId: String
    var memberIds: [String]
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, roomId, name, inviteCode, creatorId, memberIds, createdAt
    }
}

struct SharedCourse: Identifiable, Codable {
    @DocumentID var id: String?
    var courseId: String
    var courseName: String
    var region: String
    var tag: CourseTag
    var places: [Place]
    var sharedBy: String
    var sharedByNickname: String
    var sharedAt: Date
    var voteCount: Int
    var votedUserIds: [String]

    enum CodingKeys: String, CodingKey {
        case id, courseId, courseName, region, tag, places
        case sharedBy, sharedByNickname, sharedAt, voteCount, votedUserIds
    }
}

struct RoomMember: Identifiable, Codable {
    @DocumentID var id: String?
    var userId: String
    var nickname: String
    var joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, userId, nickname, joinedAt
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
