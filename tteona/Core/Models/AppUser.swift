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
    var profileImageUrl: String?

    init(uid: String, email: String, nickname: String = "", createdAt: Date = Date(), blockedUserIds: [String]? = nil) {
        self.uid = uid
        self.email = email
        self.nickname = nickname
        self.createdAt = createdAt
        self.blockedUserIds = blockedUserIds
    }

    enum CodingKeys: String, CodingKey {
        case uid, email, nickname, createdAt, isVerified, creatorLabel, blockedUserIds, profileImageUrl
    }

    // 누락 필드(예: 오래된 계정의 isVerified)가 있어도 디코딩이 실패하지 않도록 관대하게 처리.
    // Swift 합성 Decodable은 기본값을 쓰지 않고 키 누락 시 throw하므로 직접 구현.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid            = (try? c.decode(String.self, forKey: .uid)) ?? ""
        email          = (try? c.decode(String.self, forKey: .email)) ?? ""
        nickname       = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        createdAt      = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        isVerified     = (try? c.decode(Bool.self, forKey: .isVerified)) ?? false
        creatorLabel   = try? c.decode(String.self, forKey: .creatorLabel)
        blockedUserIds = try? c.decode([String].self, forKey: .blockedUserIds)
        profileImageUrl = try? c.decode(String.self, forKey: .profileImageUrl)
    }
}
