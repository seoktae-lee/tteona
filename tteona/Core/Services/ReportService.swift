import Foundation
import FirebaseFirestore

class ReportService {
    static let shared = ReportService()
    private let db = Firestore.firestore()
    private init() {}

    func reportContent(reporterId: String, targetType: String, targetId: String, targetAuthorId: String, reason: String) async throws {
        let reportRef = db.collection("reports").document()
        let data: [String: Any] = [
            "reportId": reportRef.documentID,
            "reporterId": reporterId,
            "targetType": targetType,
            "targetId": targetId,
            "targetAuthorId": targetAuthorId,
            "reason": reason,
            "createdAt": FieldValue.serverTimestamp()
        ]
        try await reportRef.setData(data)
    }
}
