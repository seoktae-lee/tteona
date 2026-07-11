import Foundation
import Combine

struct ChatMessage: Identifiable, Equatable {
    var id: String          // 서버 messageId(uuid). 낙관적 메시지는 확정 전까지 clientMsgId
    let userId: String
    let nickname: String
    let text: String
    let createdAt: Date
    var replyToNickname: String? = nil   // 답장 인용 — 원본 작성자
    var replyToText: String? = nil       // 답장 인용 — 원본 내용
    var reactions: [String: Set<String>] = [:]  // 이모지 → 반응한 userId 집합
    var pending: Bool = false   // 서버 확정 전 낙관적 표시
    var failed: Bool = false    // 전송 실패(타임아웃) — 재전송 가능

    var hasReply: Bool { replyToNickname != nil }

    // 화면 표시용 반응 목록 (이모지, 개수, 내가 눌렀는지) — 개수 내림차순
    func reactionChips(myUserId: String) -> [(emoji: String, count: Int, mine: Bool)] {
        reactions
            .filter { !$0.value.isEmpty }
            .map { (emoji: $0.key, count: $0.value.count, mine: $0.value.contains(myUserId)) }
            .sorted { $0.count > $1.count }
    }

    static func == (l: ChatMessage, r: ChatMessage) -> Bool {
        l.id == r.id && l.pending == r.pending && l.failed == r.failed && l.reactions == r.reactions
    }
}

@MainActor
class ChatSocketService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isConnected = false
    /// 금칙어로 서버가 메시지를 차단했을 때 true — 뷰에서 안내 알림 표시 후 리셋
    @Published var moderationBlocked = false
    /// 더 이전 메시지가 남아 있는가 (페이지네이션)
    @Published var canLoadOlder = false
    @Published var isLoadingOlder = false

    private var wsTask: URLSessionWebSocketTask?
    private var roomId: String?
    private var userId: String?
    private var nickname: String = ""
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?

    /// 서버의 join 확정(ack)을 받았는가 — 이게 true여야 실제 전송이 나간다.
    private var joined = false
    /// 아직 서버가 확정하지 않은 내 채팅 페이로드 (clientMsgId → payload).
    /// 미연결/재연결 구간에 보낸 메시지를 잃지 않고, join 확정 시 한꺼번에 재전송한다.
    private var outbox: [String: [String: Any]] = [:]
    /// clientMsgId별 전송 타임아웃 태스크 — 확정되면 취소, 만료되면 실패 표시.
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private let sendTimeout: Duration = .seconds(12)

    private let wsURL = URL(string: "wss://tteona.kr/ws/location")!
    private let apiBase = "https://tteona.kr/api"

    // MARK: - 연결 (히스토리 로드 → WebSocket)

    func connect(roomId: String, userId: String, nickname: String) {
        self.roomId = roomId
        self.userId = userId
        self.nickname = nickname
        Task {
            await loadHistory(roomId: roomId)
            openSocket()
        }
    }

    private func parseRows(_ rows: [[String: Any]]) -> [ChatMessage] {
        rows.compactMap { row in
            guard let uid = row["user_id"] as? String,
                  let nick = row["nickname"] as? String,
                  let text = row["text"] as? String else { return nil }
            // message_id(uuid) 우선, 구 메시지(널)는 srv_<dbid> 폴백
            let msgId: String = (row["message_id"] as? String)
                ?? (row["id"] as? Int).map { "srv_\($0)" }
                ?? UUID().uuidString
            let date = ChatSocketService.parseDate(row["created_at"] as? String) ?? Date()
            var reactions: [String: Set<String>] = [:]
            if let rx = row["reactions"] as? [[String: Any]] {
                for r in rx {
                    if let e = r["emoji"] as? String, let u = r["userId"] as? String {
                        reactions[e, default: []].insert(u)
                    }
                }
            }
            return ChatMessage(id: msgId, userId: uid, nickname: nick, text: text,
                               createdAt: date,
                               replyToNickname: row["reply_to_nickname"] as? String,
                               replyToText: row["reply_to_text"] as? String,
                               reactions: reactions)
        }
    }

    private func loadHistory(roomId: String) async {
        guard let url = URL(string: "\(apiBase)/rooms/\(roomId)/messages?limit=50") else { return }
        guard let (data, _) = try? await APIAuth.get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["messages"] as? [[String: Any]] else { return }
        messages = parseRows(rows)
        canLoadOlder = rows.count >= 50   // 50개 꽉 찼으면 더 있을 수 있음
    }

    /// 위로 스크롤해 더 이전 메시지를 불러온다(서버 before 커서 페이지네이션).
    func loadOlderMessages() async {
        guard let roomId, !isLoadingOlder, canLoadOlder,
              let oldest = messages.first(where: { !$0.pending && !$0.failed })?.createdAt else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let beforeStr = f.string(from: oldest)
        guard let enc = beforeStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(apiBase)/rooms/\(roomId)/messages?limit=30&before=\(enc)"),
              let (data, _) = try? await APIAuth.get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["messages"] as? [[String: Any]] else { return }

        let older = parseRows(rows)
        let existingIds = Set(messages.map(\.id))
        let newOnes = older.filter { !existingIds.contains($0.id) }
        if newOnes.isEmpty || rows.count < 30 { canLoadOlder = false }
        messages.insert(contentsOf: newOnes, at: 0)
    }

    private func openSocket() {
        let session = URLSession(configuration: .default)
        wsTask = session.webSocketTask(with: wsURL)
        wsTask?.resume()
        listen()
        startPing()
        // 서버가 join 시 Firebase ID 토큰으로 본인·방 멤버십을 검증한다.
        // isConnected는 낙관적으로 true로 두지 않는다 — 서버의 "joined" 확정을 받아야
        // 진짜 연결된 것이므로 그때 true로 만들고 밀린 메시지를 flush한다.
        Task { [weak self] in
            guard let self else { return }
            let token = await APIAuth.bearerToken()
            self.send(["type": "join",
                       "roomId": self.roomId ?? "",
                       "userId": self.userId ?? "",
                       "nickname": self.nickname,
                       "idToken": token ?? ""])
        }
    }

    // MARK: - 전송 (낙관적 추가)

    func sendChat(_ raw: String, replyTo: ChatMessage? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let userId else { return }
        let clientMsgId = UUID().uuidString
        messages.append(ChatMessage(id: clientMsgId, userId: userId, nickname: nickname,
                                    text: text, createdAt: Date(),
                                    replyToNickname: replyTo?.nickname,
                                    replyToText: replyTo?.text,
                                    pending: true))
        var payload: [String: Any] = ["type": "chat", "text": text, "clientMsgId": clientMsgId]
        if let replyTo {
            payload["replyToNickname"] = replyTo.nickname
            payload["replyToText"] = replyTo.text
        }
        outbox[clientMsgId] = payload
        deliver(clientMsgId)
    }

    /// 실패 표시된 메시지를 사용자가 다시 보낸다.
    func resend(_ message: ChatMessage) {
        guard message.failed, outbox[message.id] != nil else { return }
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].failed = false
            messages[idx].pending = true
        }
        deliver(message.id)
    }

    /// 조인 확정 상태면 즉시 전송, 아니면 outbox에 남겨 join 시 flush에 맡긴다.
    /// 어느 경우든 타임아웃을 걸어 무한 pending을 막는다.
    private func deliver(_ clientMsgId: String) {
        guard let payload = outbox[clientMsgId] else { return }
        if joined, wsTask?.state == .running {
            send(payload)
        }
        scheduleTimeout(clientMsgId)
    }

    private func scheduleTimeout(_ clientMsgId: String) {
        timeoutTasks[clientMsgId]?.cancel()
        timeoutTasks[clientMsgId] = Task { [weak self] in
            try? await Task.sleep(for: self?.sendTimeout ?? .seconds(12))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.markFailed(clientMsgId) }
        }
    }

    private func markFailed(_ clientMsgId: String) {
        // 아직 outbox에 남아 있으면(= 서버 확정 못 받음) 실패로 표시. 확정됐으면 무시.
        guard outbox[clientMsgId] != nil,
              let idx = messages.firstIndex(where: { $0.id == clientMsgId }) else { return }
        messages[idx].pending = false
        messages[idx].failed = true
    }

    private func confirmSent(_ clientMsgId: String) {
        outbox[clientMsgId] = nil
        timeoutTasks[clientMsgId]?.cancel()
        timeoutTasks[clientMsgId] = nil
    }

    /// join 확정 시 아직 확정 못 받은 메시지를 모두 재전송한다.
    private func flushOutbox() {
        for (clientMsgId, payload) in outbox {
            send(payload)
            if let idx = messages.firstIndex(where: { $0.id == clientMsgId }) {
                messages[idx].failed = false
                messages[idx].pending = true
            }
            scheduleTimeout(clientMsgId)
        }
    }

    // MARK: - 해제

    func disconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        if let roomId, let userId {
            send(["type": "leave", "roomId": roomId, "userId": userId])
        }
        cleanup()
        isConnected = false
        joined = false
        // 화면을 떠나므로 대기 중인 전송 타임아웃도 정리
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
    }

    private func cleanup() {
        pingTimer?.invalidate(); pingTimer = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    // MARK: - 수신

    private func listen() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Task { @MainActor in self.handle(json) }
                }
                self.listen()
            case .failure:
                Task { @MainActor in self.scheduleReconnect() }
            }
        }
    }

    private func handle(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        // 서버 join 확정 — 이제부터 진짜 연결. 미연결 구간에 쌓인 메시지를 flush.
        if type == "joined" {
            joined = true
            isConnected = true
            flushOutbox()
            return
        }

        // 서버가 인증/멤버십 검증에 실패해 연결을 끊음 — 연결 끊김으로 처리
        if type == "auth_error" {
            joined = false
            isConnected = false
            return
        }

        // 금칙어 차단 — 낙관적으로 띄웠던 내 메시지를 제거하고 안내
        if type == "chat_blocked" {
            if let clientMsgId = json["clientMsgId"] as? String {
                messages.removeAll { $0.id == clientMsgId }
                confirmSent(clientMsgId)   // outbox·타임아웃 정리 (재전송 방지)
            }
            moderationBlocked = true
            return
        }

        // 이모지 반응 업데이트
        if type == "reaction" {
            guard let messageId = json["messageId"] as? String,
                  let emoji = json["emoji"] as? String,
                  let uid = json["userId"] as? String,
                  let added = json["added"] as? Bool,
                  let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
            if added { messages[idx].reactions[emoji, default: []].insert(uid) }
            else {
                messages[idx].reactions[emoji]?.remove(uid)
                if messages[idx].reactions[emoji]?.isEmpty == true { messages[idx].reactions[emoji] = nil }
            }
            return
        }

        guard type == "chat",
              let uid  = json["userId"]   as? String,
              let nick = json["nickname"] as? String,
              let text = json["text"]     as? String else { return }
        let ts = (json["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let clientMsgId = json["clientMsgId"] as? String
        let messageId = (json["messageId"] as? String) ?? clientMsgId.map { "cli_\($0)" } ?? "\(uid)_\(ts.timeIntervalSince1970)"

        // 내가 보낸 낙관적 메시지의 에코면 서버 messageId로 확정
        if let clientMsgId, uid == userId,
           let idx = messages.firstIndex(where: { $0.id == clientMsgId }) {
            messages[idx].id = messageId
            messages[idx].pending = false
            messages[idx].failed = false
            confirmSent(clientMsgId)   // outbox·타임아웃 정리
            return
        }
        // 내 메시지 에코인데 이미 messages에 없더라도(재연결 등) outbox는 확정 처리
        if let clientMsgId, uid == userId {
            confirmSent(clientMsgId)
        }
        // 중복 방지 (재연결 시 서버 에코 등)
        guard !messages.contains(where: { $0.id == messageId }) else { return }
        messages.append(ChatMessage(id: messageId, userId: uid, nickname: nick, text: text, createdAt: ts,
                                    replyToNickname: json["replyToNickname"] as? String,
                                    replyToText: json["replyToText"] as? String))
    }

    // MARK: - 이모지 반응 토글 (낙관적)

    func toggleReaction(messageId: String, emoji: String) {
        guard let userId, let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        // 낙관적 반영
        if messages[idx].reactions[emoji]?.contains(userId) == true {
            messages[idx].reactions[emoji]?.remove(userId)
            if messages[idx].reactions[emoji]?.isEmpty == true { messages[idx].reactions[emoji] = nil }
        } else {
            messages[idx].reactions[emoji, default: []].insert(userId)
        }
        send(["type": "reaction", "messageId": messageId, "emoji": emoji])
    }

    // 답장 인용 블록 → 원본 메시지 id 찾기 (닉네임+내용 일치, 해당 답장 이전 것 중 최신)
    func originalMessageId(for reply: ChatMessage) -> String? {
        guard let nick = reply.replyToNickname, let text = reply.replyToText else { return nil }
        return messages
            .filter { $0.nickname == nick && $0.text == text && $0.createdAt <= reply.createdAt }
            .last?.id
    }

    // MARK: - 재연결 / Ping

    private func scheduleReconnect() {
        guard roomId != nil else { return }
        cleanup()
        isConnected = false
        joined = false   // 재연결 후 "joined" ack를 다시 받아야 전송 재개(+outbox flush)
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run { self.openSocket() }
        }
    }

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.wsTask?.sendPing { _ in }
        }
    }

    private func send(_ dict: [String: Any]) {
        guard let wsTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        wsTask.send(.string(str)) { _ in }
    }

    // MARK: - 날짜 파싱 (PostgreSQL ISO8601, 소수초 유무 모두 대응)

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }
}
