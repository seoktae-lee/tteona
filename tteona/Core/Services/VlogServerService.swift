import Foundation

// 서버 사이드 Vlog 생성 클라이언트.
// 흐름: 잡 생성 → 클립 업로드 → start → 진행률 폴링 → 완성본 다운로드.
// 어느 단계든 실패하면 throw → 호출부(VlogGenerationView)가 로컬 합성으로 폴백.
actor VlogServerService {
    static let shared = VlogServerService()

    private let baseURL = "https://tteona.kr/api/vlog"

    enum ServerVlogError: LocalizedError {
        case noClips
        case badResponse(String)
        case processingFailed(String)

        var errorDescription: String? {
            switch self {
            case .noClips:                  return "업로드할 클립이 없어요."
            case .badResponse(let m):       return "서버 응답 오류: \(m)"
            case .processingFailed(let m):  return "서버 편집 실패: \(m)"
            }
        }
    }

    private struct OutputItem: Decodable {
        let format: String   // "reels" | "youtube" | "insta"
        let url: String
    }

    private struct JobStatus: Decodable {
        let status: String
        let progress: Int
        let outputUrl: String?
        let outputs: [OutputItem]?
        let errorMsg: String?
    }

    struct GeneratedVlog {
        let main: URL                          // 촬영 방향 기본 버전
        let extras: [(format: String, url: URL)]  // 유저가 추가 선택한 포맷들
    }

    struct BgmTrack: Decodable {
        let id: String     // "mood/파일명" — 잡 생성 시 bgm 필드로 전달
        let name: String
        let mood: String
        let url: String    // 미리듣기 스트리밍 URL
    }

    /// BGM 선택 화면용 트랙 목록
    func fetchBgmTracks() async throws -> [BgmTrack] {
        guard let url = URL(string: "\(baseURL)/bgm") else { throw ServerVlogError.badResponse("bad url") }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServerVlogError.badResponse("bgm list failed")
        }
        struct Wrapper: Decodable { let tracks: [BgmTrack] }
        return try JSONDecoder().decode(Wrapper.self, from: data).tracks
    }

    // MARK: - 전체 오케스트레이션

    /// 서버에서 Vlog 합성 후 로컬 임시 파일 URL 반환.
    /// formats: 추가 생성할 포맷 — 촬영 방향 기본본은 항상 생성.
    /// bgm: "auto"(태그 기반 자동) | "none"(음악 없음) | "mood/파일명"(지정 트랙)
    /// onProgress: (0.0~1.0, 단계 설명 텍스트)
    func generate(course: Course, sessionId: String, userId: String, formats: [String],
                  bgm: String = "auto",
                  onProgress: @escaping @MainActor (Double, String) -> Void) async throws -> GeneratedVlog {

        // 로컬에 실제 존재하는 클립만 수집
        let clips: [(place: Place, file: URL)] = course.places.compactMap { place in
            let url = VlogService.clipURL(place: place, sessionId: sessionId)
            return FileManager.default.fileExists(atPath: url.path) ? (place, url) : nil
        }
        guard !clips.isEmpty else { throw ServerVlogError.noClips }

        await onProgress(0.02, "서버에 편집을 준비하고 있어요")

        // 1) 잡 생성 (태그 → BGM 무드, formats → 추가 포맷, shotAt → 클립별 촬영시각 자막)
        let df = DateFormatter()
        df.dateFormat = "yyyy.MM.dd  HH:mm"
        let placesPayload: [[String: Any]] = clips.map { clip in
            let shot = (try? FileManager.default.attributesOfItem(atPath: clip.file.path)[.creationDate] as? Date) ?? Date()
            return ["order": clip.place.order, "placeName": clip.place.placeName, "shotAt": df.string(from: shot)]
        }
        let jobId = try await createJob(
            userId: userId,
            courseId: course.courseId,
            courseName: course.courseName,
            tag: course.tag.rawValue,
            formats: formats,
            bgm: bgm,
            placesPayload: placesPayload
        )

        // 2) 클립 업로드 (0.05 → 0.45)
        for (i, clip) in clips.enumerated() {
            await onProgress(0.05 + 0.40 * Double(i) / Double(clips.count),
                             "클립 업로드 중 (\(i + 1)/\(clips.count))")
            try await uploadClip(jobId: jobId, order: clip.place.order, fileURL: clip.file)
        }
        await onProgress(0.45, "서버에서 편집 중이에요")

        // 3) 합성 시작
        try await startJob(jobId: jobId)

        // 4) 진행률 폴링 (0.45 → 0.88) — 최대 10분
        var outputUrl: String?
        var outputs: [OutputItem] = []
        for _ in 0..<300 {
            try await Task.sleep(for: .seconds(2))
            let st = try await status(jobId: jobId)
            switch st.status {
            case "completed":
                outputUrl = st.outputUrl
                outputs = st.outputs ?? []
            case "failed":
                throw ServerVlogError.processingFailed(st.errorMsg ?? "unknown")
            default:
                await onProgress(0.45 + 0.43 * Double(st.progress) / 100.0, "서버에서 편집 중이에요")
            }
            if outputUrl != nil { break }
        }
        guard let outputUrl else { throw ServerVlogError.processingFailed("timeout") }

        // 5) 완성본 다운로드 (0.88 → 0.98) — 기본본 + 추가 포맷들
        await onProgress(0.90, "완성본을 받아오고 있어요")
        let mainLocal = try await download(urlString: outputUrl)
        var extras: [(format: String, url: URL)] = []
        let extraItems = outputs.filter { $0.url != outputUrl }
        for (i, item) in extraItems.enumerated() {
            await onProgress(0.92 + 0.05 * Double(i) / Double(max(extraItems.count, 1)),
                             "선택한 포맷 버전을 받아오고 있어요")
            if let local = try? await download(urlString: item.url) {   // 부가 기능 — 실패해도 메인 유지
                extras.append((item.format, local))
            }
        }
        await onProgress(0.98, "거의 다 됐어요")
        return GeneratedVlog(main: mainLocal, extras: extras)
    }

    // MARK: - API 단계별 호출

    private func createJob(userId: String, courseId: String, courseName: String, tag: String,
                           formats: [String], bgm: String,
                           placesPayload: [[String: Any]]) async throws -> Int {
        guard let url = URL(string: "\(baseURL)/jobs") else { throw ServerVlogError.badResponse("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "userId": userId,
            "courseId": courseId,
            "courseName": courseName,
            "tag": tag,
            "formats": formats,
            "bgm": bgm,
            "places": placesPayload,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobId = json["jobId"] as? Int else {
            throw ServerVlogError.badResponse("job create failed")
        }
        return jobId
    }

    private func uploadClip(jobId: Int, order: Int, fileURL: URL) async throws {
        guard let url = URL(string: "\(baseURL)/jobs/\(jobId)/clips?order=\(order)") else {
            throw ServerVlogError.badResponse("bad url")
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // 영상은 크므로 메모리에 올리지 않고, multipart 바디를 임시 파일로 조립해 스트리밍 업로드
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlog_upload_\(jobId)_\(order).tmp")
        try? FileManager.default.removeItem(at: bodyFile)

        let prefix = "--\(boundary)\r\nContent-Disposition: form-data; name=\"clip\"; filename=\"\(order).mp4\"\r\nContent-Type: video/mp4\r\n\r\n"
        let suffix = "\r\n--\(boundary)--\r\n"

        FileManager.default.createFile(atPath: bodyFile.path, contents: prefix.data(using: .utf8))
        let writer = try FileHandle(forWritingTo: bodyFile)
        defer { try? writer.close(); try? FileManager.default.removeItem(at: bodyFile) }
        try writer.seekToEnd()

        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try writer.write(contentsOf: suffix.data(using: .utf8)!)
        try writer.close()

        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: bodyFile)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "upload failed"
            throw ServerVlogError.badResponse("clip \(order): \(msg.prefix(120))")
        }
    }

    private func startJob(jobId: Int) async throws {
        guard let url = URL(string: "\(baseURL)/jobs/\(jobId)/start") else { throw ServerVlogError.badResponse("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServerVlogError.badResponse("start failed")
        }
    }

    private func status(jobId: Int) async throws -> JobStatus {
        guard let url = URL(string: "\(baseURL)/jobs/\(jobId)") else { throw ServerVlogError.badResponse("bad url") }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServerVlogError.badResponse("status failed")
        }
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }

    private func download(urlString: String) async throws -> URL {
        guard let url = URL(string: urlString) else { throw ServerVlogError.badResponse("bad output url") }
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServerVlogError.badResponse("download failed")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlog_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
