import Foundation
import FirebaseFirestore

@MainActor
class UserService: ObservableObject {
    @Published var currentUser: AppUser?

    private let db = Firestore.firestore()

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
}
