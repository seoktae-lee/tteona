import Foundation
import FirebaseFirestore

struct AppUser: Codable, Equatable {
    var uid: String
    var email: String
    var nickname: String
    var createdAt: Date

    init(uid: String, email: String, nickname: String = "", createdAt: Date = Date()) {
        self.uid = uid
        self.email = email
        self.nickname = nickname
        self.createdAt = createdAt
    }
}
