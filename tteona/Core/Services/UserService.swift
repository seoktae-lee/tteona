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
        try db.collection("users").document(user.uid).setData(from: user)
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
