import SwiftUI

// 채팅 메시지 + 여행 활동(피드) 시스템 메시지를 시간순으로 합친 타임라인 엔트리
private enum ChatTimelineEntry: Identifiable {
    case message(ChatMessage)
    case system(FeedItem)

    var id: String {
        switch self {
        case .message(let m): return "m_\(m.id)"
        case .system(let f):  return "s_\(f.feedId)"
        }
    }
    var date: Date {
        switch self {
        case .message(let m): return m.createdAt
        case .system(let f):  return f.createdAt
        }
    }
}

struct GroupChatView: View {
    let room: Room

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService

    @StateObject private var chat = ChatSocketService()
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var uid: String { authService.currentUser?.uid ?? "" }
    private var myNickname: String { userService.currentUser?.nickname ?? "멤버" }

    private var entries: [ChatTimelineEntry] {
        var all: [ChatTimelineEntry] = chat.messages.map { .message($0) }
        all += roomService.feedItems.map { .system($0) }
        return all.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .message(let m):
                                ChatBubble(message: m, isMine: m.userId == uid)
                                    .id(entry.id)
                            case .system(let f):
                                SystemMessageRow(text: GroupChatView.systemText(for: f))
                                    .id(entry.id)
                            }
                        }
                        Color.clear.frame(height: 1).id("BOTTOM")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onChange(of: entries.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
            }
            inputBar
        }
        .background(Color.tteBackground)
        .onAppear {
            chat.connect(roomId: room.roomId, userId: uid, nickname: myNickname)
            // 이 방을 보고 있는 동안엔 채팅 푸시 배너 억제
            AppNotificationManager.shared.activeChatRoom = PendingChatRoom(roomId: room.roomId, targetUserId: "")
            AppNotificationManager.shared.currentUserId = uid
        }
        .onDisappear {
            chat.disconnect()
            if AppNotificationManager.shared.activeChatRoom?.roomId == room.roomId {
                AppNotificationManager.shared.activeChatRoom = nil
            }
        }
    }

    // MARK: - 입력 바

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("메시지 입력...", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.secondarySystemBackground)))
                .focused($inputFocused)

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSend ? Color.tteOrange : Color.tteMediumGray.opacity(0.4)))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Color.tteBackground
                .overlay(Rectangle().fill(Color(UIColor.separator)).frame(height: 0.5), alignment: .top)
        )
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft
        draft = ""
        chat.sendChat(text)
    }

    // MARK: - 피드 → 시스템 메시지 텍스트

    static func systemText(for item: FeedItem) -> String {
        switch item.type {
        case .tripStart:     return "🚀 \(item.nickname)님이 \(item.courseName) 여행을 시작했어요"
        case .tripEnd:       return "✅ \(item.nickname)님이 \(item.courseName) 여행을 종료했어요"
        case .arrival:       return "📍 \(item.nickname)님이 \(item.placeName ?? "")에 도착했어요"
        case .photo:         return "📸 \(item.nickname)님이 사진을 공유했어요"
        case .freeTripStart: return "🗺️ \(item.nickname)님이 나의 오늘을 시작했어요"
        case .freeCapture:   return "📸 \(item.nickname)님이 \(item.placeName ?? "이곳")에서 영상을 남겼어요"
        case .freeTripEnd:   return "✅ \(item.nickname)님의 오늘이 끝났어요 · \(item.courseName)"
        }
    }
}

// MARK: - 말풍선

private struct ChatBubble: View {
    let message: ChatMessage
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine {
                    Text(message.nickname)
                        .font(.system(size: 11))
                        .foregroundColor(.tteMediumGray)
                        .padding(.leading, 4)
                }
                HStack(alignment: .bottom, spacing: 5) {
                    if isMine { timeLabel }
                    Text(message.text)
                        .font(.system(size: 15))
                        .foregroundColor(isMine ? .white : .tteDarkGray)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(isMine ? Color.tteOrange.opacity(message.pending ? 0.55 : 1.0)
                                             : Color(UIColor.secondarySystemBackground))
                        )
                    if !isMine { timeLabel }
                }
            }
            if !isMine { Spacer(minLength: 40) }
        }
    }

    private var timeLabel: some View {
        Text(message.createdAt.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 10))
            .foregroundColor(.tteMediumGray.opacity(0.7))
    }
}

// MARK: - 시스템(활동) 메시지

private struct SystemMessageRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.tteMediumGray)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(UIColor.secondarySystemBackground).opacity(0.7)))
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
