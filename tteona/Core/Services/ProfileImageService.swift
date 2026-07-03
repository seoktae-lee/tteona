import Foundation
import UIKit

actor ProfileImageService {
    static let shared = ProfileImageService()

    private let baseURL = "https://tteona.kr/api/users"

    // MARK: - 업로드 (multipart/form-data, 필드명 "image")

    @discardableResult
    func upload(uid: String, image: UIImage) async -> String? {
        // 원본 대신 축소본 전송 — 서버가 512로 리샘플하고, 업로드 한도(용량)도 안전
        guard let jpeg = ImageUploadHelper.downscaledJPEG(image) else { return nil }
        guard let url = URL(string: "\(baseURL)/\(uid)/avatar") else { return nil }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(uid).jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        do {
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["url"] as? String
        } catch {
            print("[ProfileImageService] upload error:", error)
            return nil
        }
    }
}
