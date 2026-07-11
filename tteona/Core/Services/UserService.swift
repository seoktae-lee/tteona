import Foundation
import Combine
import FirebaseFirestore

@MainActor
class UserService: ObservableObject {
    @Published var currentUser: AppUser?

    private let db = Firestore.firestore()
    private var authorCache: [String: AppUser] = [:]

    func fetchAuthor(uid: String) async -> AppUser? {
        if let cached = authorCache[uid] { return cached }
        let doc = try? await db.collection("users").document(uid).getDocument()
        let user = try? doc?.data(as: AppUser.self)
        if let user { authorCache[uid] = user }
        return user
    }

    func fetchUser(uid: String) async {
        let doc = try? await db.collection("users").document(uid).getDocument()
        currentUser = try? doc?.data(as: AppUser.self)
    }

    func saveUser(_ user: AppUser) async throws {
        // merge: true — AppUser에 없는 필드(likedCourseIds·visitedSigCodes·
        // footprintBackfillV1 등)와 nil 옵셔널(profileImageUrl·blockedUserIds)이
        // 통째로 덮어써져 사라지는 것을 막는다. 온보딩을 다시 밟은 기존 유저의
        // 좋아요·발자취·프로필 사진을 보존한다.
        try db.collection("users").document(user.uid).setData(from: user, merge: true)
        // 과거 버전이 공개 users 문서에 저장해 둔 email(PII)이 남아 있으면 제거한다.
        try? await db.collection("users").document(user.uid).updateData(["email": FieldValue.delete()])
        currentUser = user
    }

    func isNewUser(uid: String) async -> Bool {
        let doc = try? await db.collection("users").document(uid).getDocument()
        return !(doc?.exists ?? false)
    }

    func updateNickname(uid: String, nickname: String) async throws {
        try await db.collection("users").document(uid).updateData(["nickname": nickname])
        currentUser?.nickname = nickname
    }

    /// 선호 여행 태그 저장 (nil이면 해제) — 탐색 탭 추천 개인화에 사용
    func updatePreferredTag(uid: String, tag: String?) async throws {
        try await db.collection("users").document(uid).updateData([
            "preferredTag": tag ?? FieldValue.delete()
        ])
        currentUser?.preferredTag = tag
    }

    // WAS 업로드 라우트가 Firestore profileImageUrl 필드도 함께 저장하므로,
    // 여기서는 원격 쓰기 없이 로컬 상태만 갱신한다.
    func setProfileImageUrl(_ url: String) {
        currentUser?.profileImageUrl = url
    }

    /// 닉네임을 원자적으로 예약한다(중복 방지). 성공 true, 이미 남이 선점했으면 false.
    /// nicknames/{닉네임} 문서를 create-only 규칙으로 만들어, 동시 가입 레이스에서도 선점이 원자적.
    /// (기존 유저는 예약 문서가 없으므로 호출부에서 isNicknameTaken 검사도 함께 쓴다.)
    func reserveNickname(_ nickname: String, uid: String) async -> Bool {
        let key = nickname.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return false }
        let ref = db.collection("nicknames").document(key)
        do {
            try await ref.setData(["uid": uid, "createdAt": FieldValue.serverTimestamp()])
            return true
        } catch {
            // 이미 존재 — 내가 소유한 예약이면(재시도 등) 성공으로 간주
            let doc = try? await ref.getDocument()
            return (doc?.data()?["uid"] as? String) == uid
        }
    }

    /// 내 닉네임 예약을 반납한다(닉네임 변경 시 옛 닉네임 해제).
    func releaseNickname(_ nickname: String, uid: String) async {
        let key = nickname.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        let ref = db.collection("nicknames").document(key)
        if let doc = try? await ref.getDocument(), (doc.data()?["uid"] as? String) == uid {
            try? await ref.delete()
        }
    }

    func isNicknameTaken(_ nickname: String) async -> Bool {
        let snapshot = try? await db.collection("users")
            .whereField("nickname", isEqualTo: nickname.trimmingCharacters(in: .whitespaces))
            .limit(to: 1)
            .getDocuments()
        return !(snapshot?.documents.isEmpty ?? true)
    }

    func blockUser(uid: String, blockedUid: String) async throws {
        guard uid != blockedUid else { return }
        try await db.collection("users").document(uid).updateData([
            "blockedUserIds": FieldValue.arrayUnion([blockedUid])
        ])
        if currentUser?.uid == uid {
            if currentUser?.blockedUserIds == nil {
                currentUser?.blockedUserIds = []
            }
            if !(currentUser?.blockedUserIds?.contains(blockedUid) ?? false) {
                currentUser?.blockedUserIds?.append(blockedUid)
            }
        }
    }

    func unblockUser(uid: String, blockedUid: String) async throws {
        try await db.collection("users").document(uid).updateData([
            "blockedUserIds": FieldValue.arrayRemove([blockedUid])
        ])
        if currentUser?.uid == uid {
            currentUser?.blockedUserIds?.removeAll { $0 == blockedUid }
        }
    }
}
