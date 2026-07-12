import Foundation
import UIKit

/// 방 대표 이미지 업로드 — ProfileImageService와 동일한 WAS multipart 경로.
/// 서버가 512 정사각 리샘플 후 rooms 문서의 imageUrl을 갱신하므로
/// myRooms 스냅샷 리스너를 통해 전 멤버 화면에 즉시 반영된다.
actor RoomImageService {
    static let shared = RoomImageService()

    private let baseURL = "https://tteona.kr/api/rooms"

    @discardableResult
    func upload(roomId: String, image: UIImage) async -> String? {
        guard let jpeg = ImageUploadHelper.downscaledJPEG(image) else { return nil }
        guard let url = URL(string: "\(baseURL)/\(roomId)/image") else { return nil }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        await APIAuth.authorize(&request)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(roomId).jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        do {
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["url"] as? String
        } catch {
            dlog("[RoomImageService] upload error:", error)
            return nil
        }
    }
}
