import Foundation
import FirebaseFirestore

struct TteonaPlaceReview: Identifiable {
    let id: String
    let userId: String
    let nickname: String
    let rating: Int
    let comment: String?
    let createdAt: Date
}

class PlaceReviewService {
    static let shared = PlaceReviewService()
    private let db = Firestore.firestore()
    private init() {}

    func fetchReviews(placeKey: String, blockedUserIds: [String] = []) async -> (reviews: [TteonaPlaceReview], visitCount: Int) {
        guard let snapshot = try? await db
            .collection("placeReviews").document(placeKey)
            .collection("reviews")
            .order(by: "createdAt", descending: true)
            .limit(to: 20)
            .getDocuments()
        else { return ([], 0) }

        let allReviews = snapshot.documents.compactMap { doc -> TteonaPlaceReview? in
            let d = doc.data()
            guard let userId = d["userId"] as? String,
                  let nickname = d["nickname"] as? String,
                  let rating = d["rating"] as? Int,
                  let createdAt = (d["createdAt"] as? Timestamp)?.dateValue()
            else { return nil }
            return TteonaPlaceReview(
                id: doc.documentID,
                userId: userId,
                nickname: nickname,
                rating: rating,
                comment: d["comment"] as? String,
                createdAt: createdAt
            )
        }
        let reviews = allReviews.filter { !blockedUserIds.contains($0.userId) }
        return (reviews, reviews.count)
    }

    // userId를 문서 ID로 사용 → 1인당 장소별 1개 리뷰 (재방문 시 업데이트)
    func saveReview(placeKey: String, userId: String, nickname: String,
                    rating: Int, comment: String?) async {
        guard rating > 0 else { return }
        var data: [String: Any] = [
            "userId": userId,
            "nickname": nickname,
            "rating": rating,
            "createdAt": FieldValue.serverTimestamp()
        ]
        if let comment, !comment.trimmingCharacters(in: .whitespaces).isEmpty {
            data["comment"] = comment.trimmingCharacters(in: .whitespaces)
        }
        try? await db
            .collection("placeReviews").document(placeKey)
            .collection("reviews").document(userId)
            .setData(data)
    }
}
