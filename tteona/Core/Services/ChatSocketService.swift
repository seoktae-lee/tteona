import Foundation
import Combine

struct ChatMessage: Identifiable, Equatable {
    let id: String          // clientMsgId(내 메시지) 또는 server id
    let userId: String
    let nickname: String
    let text: String
    let createdAt: Date
    var pending: Bool = false   // 서버 확정 전 낙관적 표시

    static func == (l: ChatMessage, r: ChatMessage) -> Bool { l.id == r.id }
}

@MainActor
class ChatSocketService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isConnected = false

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
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["messages"] as? [[String: Any]] else { return }

        let history: [ChatMessage] = rows.compactMap { row in
            guard let uid = row["user_id"] as? String,
                  let nick = row["nickname"] as? String,
                  let text = row["text"] as? String else { return nil }
            let idVal: String = (row["id"] as? Int).map(String.init)
                ?? (row["id"] as? String) ?? UUID().uuidString
            let date = ChatSocketService.parseDate(row["created_at"] as? String) ?? Date()
            return ChatMessage(id: "srv_\(idVal)", userId: uid, nickname: nick, text: text, createdAt: date)
        }
        messages = history
    }

    private func openSocket() {
        let session = URLSession(configuration: .default)
        wsTask = session.webSocketTask(with: wsURL)
        wsTask?.resume()
        send(["type": "join", "roomId": roomId ?? "", "userId": userId ?? "", "nickname": nickname])
        isConnected = true
        listen()
        startPing()
    }

    // MARK: - 전송 (낙관적 추가)

    func sendChat(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let userId else { return }
        let clientMsgId = UUID().uuidString
        messages.append(ChatMessage(id: clientMsgId, userId: userId, nickname: nickname,
                                    text: text, createdAt: Date(), pending: true))
        send(["type": "chat", "text": text, "clientMsgId": clientMsgId])
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
        guard json["type"] as? String == "chat",
              let uid  = json["userId"]   as? String,
              let nick = json["nickname"] as? String,
              let text = json["text"]     as? String else { return }
        let ts = (json["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let clientMsgId = json["clientMsgId"] as? String

        // 내가 보낸 낙관적 메시지의 에코면 확정 처리
        if let clientMsgId, uid == userId,
           let idx = messages.firstIndex(where: { $0.id == clientMsgId }) {
            messages[idx].pending = false
            return
        }
        // 중복 방지 (재연결 시 서버 에코 등)
        let newId = clientMsgId.map { "cli_\($0)" } ?? "\(uid)_\(ts.timeIntervalSince1970)"
        guard !messages.contains(where: { $0.id == newId }) else { return }
        messages.append(ChatMessage(id: newId, userId: uid, nickname: nick, text: text, createdAt: ts))
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
