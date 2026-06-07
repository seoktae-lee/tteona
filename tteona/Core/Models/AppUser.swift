import Foundation
import FirebaseFirestore

struct AppUser: Codable, Equatable {
    var uid: String
    var email: String
    var nickname: String
    var createdAt: Date
    var isVerified: Bool = false
    var creatorLabel: String?
    var blockedUserIds: [String]?

    init(uid: String, email: String, nickname: String = "", createdAt: Date = Date(), blockedUserIds: [String]? = nil) {
        self.uid = uid
        self.email = email
        self.nickname = nickname
        self.createdAt = createdAt
        self.blockedUserIds = blockedUserIds
    }
}
