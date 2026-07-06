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

    var hasReply: Bool { replyToNickname != nil }

    // 화면 표시용 반응 목록 (이모지, 개수, 내가 눌렀는지) — 개수 내림차순
    func reactionChips(myUserId: String) -> [(emoji: String, count: Int, mine: Bool)] {
        reactions
            .filter { !$0.value.isEmpty }
            .map { (emoji: $0.key, count: $0.value.count, mine: $0.value.contains(myUserId)) }
            .sorted { $0.count > $1.count }
    }

    static func == (l: ChatMessage, r: ChatMessage) -> Bool {
        l.id == r.id && l.pending == r.pending && l.reactions == r.reactions
    }
}

@MainActor
class ChatSocketService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isConnected = false
    /// 금칙어로 서버가 메시지를 차단했을 때 true — 뷰에서 안내 알림 표시 후 리셋
    @Published var moderationBlocked = false

    private var wsTask: URLSessionWebSocketTask?
    private var roomId: String?
    private var userId: String?
    private var nickname: String = ""
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?

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

    private func loadHistory(roomId: String) async {
        guard let url = URL(string: "\(apiBase)/rooms/\(roomId)/messages?limit=50") else { return }
        guard let (data, _) = try? await APIAuth.get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["messages"] as? [[String: Any]] else { return }

        let history: [ChatMessage] = rows.compactMap { row in
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
        messages = history
    }

    private func openSocket() {
        let session = URLSession(configuration: .default)
        wsTask = session.webSocketTask(with: wsURL)
        wsTask?.resume()
        listen()
        startPing()
        // 서버가 join 시 Firebase ID 토큰으로 본인·방 멤버십을 검증한다
        Task { [weak self] in
            guard let self else { return }
            let token = await APIAuth.bearerToken()
            self.send(["type": "join",
                       "roomId": self.roomId ?? "",
                       "userId": self.userId ?? "",
                       "nickname": self.nickname,
                       "idToken": token ?? ""])
            self.isConnected = true
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
        send(payload)
    }

    // MARK: - 해제

    func disconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        if let roomId, let userId {
            send(["type": "leave", "roomId": roomId, "userId": userId])
        }
        cleanup()
        isConnected = false
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

        // 금칙어 차단 — 낙관적으로 띄웠던 내 메시지를 제거하고 안내
        if type == "chat_blocked" {
            if let clientMsgId = json["clientMsgId"] as? String {
                messages.removeAll { $0.id == clientMsgId }
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
            return
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
