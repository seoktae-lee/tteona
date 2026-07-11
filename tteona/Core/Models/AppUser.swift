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
    /// 선호 여행 태그 (CourseTag.rawValue) — 온보딩/설정에서 선택, 코스 추천 개인화에 사용
    var preferredTag: String?

    init(uid: String, email: String, nickname: String = "", createdAt: Date = Date(),
         blockedUserIds: [String]? = nil, preferredTag: String? = nil) {
        self.uid = uid
        self.email = email
        self.nickname = nickname
        self.createdAt = createdAt
        self.blockedUserIds = blockedUserIds
        self.preferredTag = preferredTag
    }

    // email은 공개 users 문서에 저장/조회하지 않는다 (PII 유출 방지) —
    // 내 이메일은 Firebase Auth(currentUser)에서 직접 읽고, 타인 이메일은 취급하지 않는다.
    // 따라서 CodingKeys에서 제외해 Firestore 인코딩/디코딩 대상에서 뺀다.
    enum CodingKeys: String, CodingKey {
        case uid, nickname, createdAt, isVerified, creatorLabel, blockedUserIds, profileImageUrl, preferredTag
    }

    // 누락 필드(예: 오래된 계정의 isVerified)가 있어도 디코딩이 실패하지 않도록 관대하게 처리.
    // Swift 합성 Decodable은 기본값을 쓰지 않고 키 누락 시 throw하므로 직접 구현.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid            = (try? c.decode(String.self, forKey: .uid)) ?? ""
        email          = ""   // Firestore에서 읽지 않음 (Auth가 소유)
        nickname       = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        createdAt      = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        isVerified     = (try? c.decode(Bool.self, forKey: .isVerified)) ?? false
        creatorLabel   = try? c.decode(String.self, forKey: .creatorLabel)
        blockedUserIds = try? c.decode([String].self, forKey: .blockedUserIds)
        profileImageUrl = try? c.decode(String.self, forKey: .profileImageUrl)
        preferredTag   = try? c.decode(String.self, forKey: .preferredTag)
    }

    // 클라이언트는 admin/Auth 소유 필드를 절대 쓰지 않는다:
    //   · isVerified / creatorLabel — Firebase 콘솔(관리자)만 설정 (Firestore 규칙도 이 둘의 변경을 차단)
    //   · email — Auth가 소유 (공개 users 문서에 PII 미저장)
    // 이걸 빼지 않으면 saveUser(merge)가 isVerified=false를 써서 인증 크리에이터를 강등하고
    // 규칙에도 막힌다. blockedUserIds 등 nil 옵셔널도 merge를 덮어쓰지 않도록 encodeIfPresent.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uid, forKey: .uid)
        try c.encode(nickname, forKey: .nickname)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(blockedUserIds, forKey: .blockedUserIds)
        try c.encodeIfPresent(profileImageUrl, forKey: .profileImageUrl)
        try c.encodeIfPresent(preferredTag, forKey: .preferredTag)
    }
}
