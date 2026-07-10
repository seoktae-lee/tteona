import Foundation

// 서버 사이드 Vlog 생성 클라이언트.
// 흐름: 잡 생성 → 클립 업로드 → start → 진행률 폴링 → 완성본 다운로드.
//
// 서버 합성본만이 BGM·워터마크·타이틀 카드를 갖는다. 로컬 폴백은 이 셋이 전부 빠진
// 열화 버전이므로, 일시적 네트워크 오류로 폴백하는 일이 없도록 다음을 지킨다:
//   1) 잡 진행 상태를 기기에 저장해 재시도 시 처음부터 다시 하지 않고 이어받는다
//   2) 업로드·다운로드는 지수 백오프로 재시도한다
//   3) 상태 폴링은 연속 실패를 일정 횟수까지 견딘다 (셀 전환·짧은 끊김 흡수)
// 그래도 실패하면 throw → 호출부(VlogGenerationView)가 오류 유형을 보고 판단한다.
actor VlogServerService {
    static let shared = VlogServerService()

    private let baseURL = "https://tteona.kr/api/vlog"

    enum ServerVlogError: LocalizedError {
        case noClips
        case badResponse(String)
        /// 서버가 명시적으로 실패를 확정한 경우 — 다시 시도해도 결과가 같다
        case processingFailed(String)
        /// 전송 계층 실패 — 서버의 잡은 아직 살아 있을 수 있어 이어받기가 가능하다
        case transient(String)
        /// 서버에 잡이 남아 있지 않음 (만료·삭제)
        case jobGone

        var errorDescription: String? {
            switch self {
            case .noClips:                  return L("vlogserver.error.noClips")
            case .badResponse(let m):       return L("vlogserver.error.badResponse", m)
            case .processingFailed(let m):  return L("vlogserver.error.processingFailed", m)
            case .transient(let m):         return L("vlogserver.error.badResponse", m)
            case .jobGone:                  return L("vlogserver.error.statusFailed")
            }
        }

        /// 서버가 "이 영상은 못 만든다"고 확정했는가 — true면 로컬 폴백 외에 방법이 없다.
        var isDefinitive: Bool {
            switch self {
            case .noClips, .processingFailed: return true
            case .badResponse, .transient, .jobGone: return false
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

    // MARK: - 진행 중인 잡 기억하기

    /// 네트워크가 끊기거나 앱이 죽어도 서버는 렌더링을 계속한다.
    /// 세션별로 잡 진행 상태를 남겨 두면 재시도 시 업로드를 건너뛰고 결과만 받아올 수 있다.
    private struct PendingJob: Codable {
        let jobId: Int
        let courseId: String
        var uploadedOrders: [Int]
        var started: Bool
        let createdAt: Date
    }

    private static let storeKey = "vlog.pendingJobs"

    private func loadStore() -> [String: PendingJob] {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([String: PendingJob].self, from: data)
        else { return [:] }
        // 하루 지난 잡은 서버에서도 정리 대상이라 들고 있을 이유가 없다
        return decoded.filter { Date().timeIntervalSince($0.value.createdAt) < 86_400 }
    }

    private func saveStore(_ store: [String: PendingJob]) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    private func loadPending(_ sessionId: String) -> PendingJob? { loadStore()[sessionId] }

    private func savePending(_ sessionId: String, _ job: PendingJob) {
        var store = loadStore()
        store[sessionId] = job
        saveStore(store)
    }

    private func clearPending(_ sessionId: String) {
        var store = loadStore()
        store.removeValue(forKey: sessionId)
        saveStore(store)
    }

    /// 이 세션에 대해 서버가 아직 붙잡고 있는 잡이 있는가 — 오류 화면에서 "이어받기" 안내에 사용
    func hasPendingJob(sessionId: String) -> Bool { loadPending(sessionId) != nil }

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
    /// watermark: false는 plus 유저 전용 (우측 상단 tteona 로고 제거)
    /// priority: true면 렌더링 큐 우선 처리 (plus 유저 전용)
    /// onProgress: (0.0~1.0, 단계 설명 텍스트)
    func generate(course: Course, sessionId: String, userId: String, formats: [String],
                  bgm: String = "auto",
                  watermark: Bool = true,
                  priority: Bool = false,
                  onProgress: @escaping @MainActor (Double, String) -> Void) async throws -> GeneratedVlog {

        // 로컬에 실제 존재하는 클립만 수집
        let clips: [(place: Place, file: URL)] = course.places.compactMap { place in
            let url = VlogService.clipURL(place: place, sessionId: sessionId)
            return FileManager.default.fileExists(atPath: url.path) ? (place, url) : nil
        }
        guard !clips.isEmpty else { throw ServerVlogError.noClips }

        await onProgress(0.02, L("vlogserver.prep"))

        // 0) 이전 시도가 남긴 잡이 있으면 이어받는다
        var pending = loadPending(sessionId)
        if let p = pending, p.courseId != course.courseId {
            clearPending(sessionId)   // 다른 코스의 잔재
            pending = nil
        }
        if let p = pending {
            await onProgress(0.05, L("vlogserver.resuming"))
            switch try? await status(jobId: p.jobId) {
            case .some(let st) where st.status == "completed":
                // 폰이 놓친 사이 서버가 이미 완성해 뒀다 — 다운로드만 하면 끝
                return try await downloadOutputs(sessionId: sessionId, outputUrl: st.outputUrl,
                                                 outputs: st.outputs ?? [], onProgress: onProgress)
            case .some(let st) where st.status == "failed":
                clearPending(sessionId)
                pending = nil
            case .some(let st):
                pending?.started = (st.status != "uploading")
            case .none:
                clearPending(sessionId)   // 404 등 — 처음부터 다시
                pending = nil
            }
        }

        // 1) 잡 생성 (태그 → BGM 무드, formats → 추가 포맷, shotAt → 클립별 촬영시각 자막)
        let jobId: Int
        var uploadedOrders: Set<Int>
        var alreadyStarted: Bool

        if let p = pending {
            jobId = p.jobId
            uploadedOrders = Set(p.uploadedOrders)
            alreadyStarted = p.started
        } else {
            let df = DateFormatter()
            df.dateFormat = "yyyy.MM.dd  HH:mm"
            let placesPayload: [[String: Any]] = clips.map { clip in
                let shot = (try? FileManager.default.attributesOfItem(atPath: clip.file.path)[.creationDate] as? Date) ?? Date()
                return ["order": clip.place.order, "placeName": clip.place.placeName, "shotAt": df.string(from: shot)]
            }
            jobId = try await createJob(
                userId: userId,
                courseId: course.courseId,
                courseName: course.courseName,
                tag: course.tag.rawValue,
                formats: formats,
                bgm: bgm,
                watermark: watermark,
                priority: priority,
                placesPayload: placesPayload
            )
            uploadedOrders = []
            alreadyStarted = false
            savePending(sessionId, PendingJob(jobId: jobId, courseId: course.courseId,
                                              uploadedOrders: [], started: false, createdAt: Date()))
        }

        // 2) 클립 업로드 (0.05 → 0.45) — 이미 올린 클립은 건너뛴다
        if !alreadyStarted {
            for (i, clip) in clips.enumerated() {
                await onProgress(0.05 + 0.40 * Double(i) / Double(clips.count),
                                 L("vlogserver.uploading", i + 1, clips.count))
                guard !uploadedOrders.contains(clip.place.order) else { continue }
                try await uploadClip(jobId: jobId, order: clip.place.order, fileURL: clip.file)
                uploadedOrders.insert(clip.place.order)
                savePending(sessionId, PendingJob(jobId: jobId, courseId: course.courseId,
                                                  uploadedOrders: Array(uploadedOrders),
                                                  started: false, createdAt: Date()))
            }
        }
        await onProgress(0.45, L("vlogserver.editing"))

        // 3) 합성 시작
        if !alreadyStarted {
            try await startJob(jobId: jobId)
            alreadyStarted = true
            savePending(sessionId, PendingJob(jobId: jobId, courseId: course.courseId,
                                              uploadedOrders: Array(uploadedOrders),
                                              started: true, createdAt: Date()))
        }

        // 4) 진행률 폴링 (0.45 → 0.88) — 최대 30분
        //    (멀티포맷 × 클립 다수 잡은 10분을 넘길 수 있음 — 조기 타임아웃하면
        //     서버가 렌더링 중인데 폰이 로컬 합성을 중복 수행하게 된다)
        //    상태 조회 한 번 삐끗했다고 포기하지 않는다: 연속 실패 15회(≈30초)까지 견딘다.
        var outputUrl: String?
        var outputs: [OutputItem] = []
        var consecutiveFailures = 0
        let deadline = Date().addingTimeInterval(30 * 60)

        while Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            let st: JobStatus
            do {
                st = try await status(jobId: jobId)
                consecutiveFailures = 0
            } catch ServerVlogError.jobGone {
                clearPending(sessionId)
                throw ServerVlogError.jobGone
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures > 15 { throw ServerVlogError.transient("status polling") }
                continue
            }
            switch st.status {
            case "completed":
                outputUrl = st.outputUrl
                outputs = st.outputs ?? []
            case "failed":
                clearPending(sessionId)
                throw ServerVlogError.processingFailed(st.errorMsg ?? "unknown")
            default:
                await onProgress(0.45 + 0.43 * Double(st.progress) / 100.0, L("vlogserver.editing"))
            }
            if outputUrl != nil { break }
        }
        // 시간이 다 됐어도 서버 잡은 살아 있다 — pending을 지우지 않아 다음 시도에 이어받는다
        guard outputUrl != nil else { throw ServerVlogError.transient("timeout") }

        // 5) 완성본 다운로드 (0.88 → 0.98) — 기본본 + 추가 포맷들
        return try await downloadOutputs(sessionId: sessionId, outputUrl: outputUrl,
                                         outputs: outputs, onProgress: onProgress)
    }

    /// 완성된 잡의 결과물을 내려받는다 — 성공 시 이 세션의 pending 기록을 지운다.
    private func downloadOutputs(sessionId: String, outputUrl: String?, outputs: [OutputItem],
                                 onProgress: @escaping @MainActor (Double, String) -> Void) async throws -> GeneratedVlog {
        guard let outputUrl else { throw ServerVlogError.transient("missing output url") }
        await onProgress(0.90, L("vlogserver.receiving"))
        let mainLocal = try await download(urlString: outputUrl)
        var extras: [(format: String, url: URL)] = []
        let extraItems = outputs.filter { $0.url != outputUrl }
        for (i, item) in extraItems.enumerated() {
            await onProgress(0.92 + 0.05 * Double(i) / Double(max(extraItems.count, 1)),
                             L("vlogserver.receivingFormats"))
            if let local = try? await download(urlString: item.url) {   // 부가 기능 — 실패해도 메인 유지
                extras.append((item.format, local))
            }
        }
        await onProgress(0.98, L("vlogserver.almostDone"))
        clearPending(sessionId)
        return GeneratedVlog(main: mainLocal, extras: extras)
    }

    // MARK: - 재시도 헬퍼

    /// 지수 백오프 재시도. 서버가 확정 실패를 알린 경우(isDefinitive)엔 즉시 포기한다.
    private func retrying<T>(_ attempts: Int, _ operation: () async throws -> T) async throws -> T {
        var lastError: Error = ServerVlogError.transient("unknown")
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(2 << (attempt - 1)))   // 2s, 4s, 8s...
            }
            do {
                return try await operation()
            } catch let error as ServerVlogError where error.isDefinitive {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - API 단계별 호출

    private func createJob(userId: String, courseId: String, courseName: String, tag: String,
                           formats: [String], bgm: String, watermark: Bool, priority: Bool,
                           placesPayload: [[String: Any]]) async throws -> Int {
        guard let url = URL(string: "\(baseURL)/jobs") else { throw ServerVlogError.badResponse("bad url") }
        return try await retrying(3) {
            let req = await APIAuth.request(url: url, method: "POST", jsonBody: [
                "userId": userId,
                "courseId": courseId,
                "courseName": courseName,
                "tag": tag,
                "formats": formats,
                "bgm": bgm,
                "watermark": watermark,
                "priority": priority,
                "places": placesPayload,
            ])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jobId = json["jobId"] as? Int else {
                throw ServerVlogError.transient("job create failed")
            }
            return jobId
        }
    }

    private func uploadClip(jobId: Int, order: Int, fileURL: URL) async throws {
        try await retrying(3) {
            try await uploadClipOnce(jobId: jobId, order: order, fileURL: fileURL)
        }
    }

    private func uploadClipOnce(jobId: Int, order: Int, fileURL: URL) async throws {
        guard let url = URL(string: "\(baseURL)/jobs/\(jobId)/clips?order=\(order)") else {
            throw ServerVlogError.badResponse("bad url")
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        await APIAuth.authorize(&req)

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
            throw ServerVlogError.transient("clip \(order): \(msg.prefix(120))")
        }
        // 서버가 저장한 바이트 수를 로컬 원본과 대조 — 다르면 전송 중 잘린 것이므로
        // 성공으로 넘기지 않고 재시도(retrying)에 맡긴다. 잘린 클립이 합성에 들어가는 것을
        // 서버 ffprobe 검증과 이중으로 차단한다.
        let localSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        if let localSize,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let savedSize = json["size"] as? Int,
           savedSize != localSize {
            throw ServerVlogError.transient("clip \(order): size mismatch \(savedSize)/\(localSize)")
        }
    }

    private func startJob(jobId: Int) async throws {
        guard let url = URL(string: "\(baseURL)/jobs/\(jobId)/start") else { throw ServerVlogError.badResponse("bad url") }
        try await retrying(3) {
            let req = await APIAuth.request(url: url, method: "POST")
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode
            if code == 200 { return }
            // 앞선 시도의 요청이 실제로는 서버에 닿았을 수 있다 (응답만 유실).
            // 그 경우 잡은 이미 uploading을 벗어나 404가 오므로, 상태로 확인해 통과시킨다.
            if let st = try? await status(jobId: jobId),
               ["pending", "processing", "completed"].contains(st.status) { return }
            throw ServerVlogError.transient("start failed")
        }
    }

    private func status(jobId: Int) async throws -> JobStatus {
        guard let url = URL(string: "\(baseURL)/jobs/\(jobId)") else { throw ServerVlogError.badResponse("bad url") }
        let (data, resp) = try await APIAuth.get(url)
        let code = (resp as? HTTPURLResponse)?.statusCode
        if code == 404 { throw ServerVlogError.jobGone }
        guard code == 200 else { throw ServerVlogError.transient("status failed") }
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }

    private func download(urlString: String) async throws -> URL {
        guard let url = URL(string: urlString) else { throw ServerVlogError.badResponse("bad output url") }
        return try await retrying(3) {
            // 완성본은 서버에서 소유자 검증을 하므로 인증 헤더 필수
            let req = await APIAuth.request(url: url)
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw ServerVlogError.transient("download failed")
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("vlog_\(UUID().uuidString).mp4")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        }
    }
}
