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
    @State private var replyingTo: ChatMessage?
    @State private var scrollTargetId: String?
    @State private var highlightedId: String?
    @FocusState private var inputFocused: Bool

    // 카톡 스타일 빠른 반응 이모지
    private let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "👏"]

    private var uid: String { authService.currentUser?.uid ?? "" }
    private var myNickname: String { userService.currentUser?.nickname ?? L("session.member") }

    // 채팅에 시스템 메시지로 노출할 활동 — 저빈도·고가치 마일스톤만.
    // 장소별 캡처(freeCapture)·사진·도착은 스팸이 되어 제외.
    private static let chatVisibleFeedTypes: Set<FeedType> = [
        .tripStart, .tripEnd, .freeTripStart, .freeTripEnd
    ]

    private var entries: [ChatTimelineEntry] {
        // 차단한 유저의 메시지·활동은 숨긴다
        let blocked = Set(userService.currentUser?.blockedUserIds ?? [])
        var all: [ChatTimelineEntry] = chat.messages
            .filter { !blocked.contains($0.userId) }
            .map { .message($0) }
        all += roomService.feedItems
            .filter { Self.chatVisibleFeedTypes.contains($0.type) && !blocked.contains($0.userId) }
            .map { .system($0) }
        return all.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // 이전 메시지 더보기 (페이지네이션) — 탭 방식이라 스크롤 위치가 튀지 않는다
                        if chat.canLoadOlder {
                            Button {
                                Task { await chat.loadOlderMessages() }
                            } label: {
                                if chat.isLoadingOlder {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Text(L("chat.loadOlder"))
                                        .font(.tte(13, .medium))
                                        .foregroundColor(.tteOrange)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        ForEach(entries) { entry in
                            switch entry {
                            case .message(let m):
                                ChatBubble(
                                    message: m,
                                    isMine: m.userId == uid,
                                    myUserId: uid,
                                    quickEmojis: quickEmojis,
                                    highlighted: highlightedId == m.id,
                                    onReply: { replyingTo = m; inputFocused = true },
                                    onReact: { emoji in chat.toggleReaction(messageId: m.id, emoji: emoji) },
                                    onQuoteTap: { scrollToOriginal(of: m) },
                                    onResend: { chat.resend(m) }
                                )
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
                // 키보드가 올라와 뷰포트가 줄어도 바닥(최신 메시지)을 계속 붙잡는다
                .defaultScrollAnchor(.bottom)
                .onChange(of: entries.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                }
                .onChange(of: inputFocused) { _, focused in
                    // 앵커만으로는 이미 위로 스크롤해 둔 상태를 보정하지 못한다 —
                    // 입력창을 탭한 순간엔 키보드 애니메이션에 맞춰 최신 메시지로 내려준다.
                    guard focused else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                    }
                }
                .onChange(of: scrollTargetId) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("m_\(target)", anchor: .center) }
                    scrollTargetId = nil
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
        .alert(L("chat.moderation.title"), isPresented: $chat.moderationBlocked) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(L("chat.moderation.message"))
        }
    }

    // MARK: - 입력 바

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let reply = replyingTo {
                replyPreview(reply)
            }
            HStack(spacing: 10) {
                TextField(L("chat.placeholder"), text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.tte(15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.secondarySystemBackground)))
                    .focused($inputFocused)

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.tte(16, .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(canSend ? Color.tteOrange : Color.tteMediumGray.opacity(0.4)))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(
            Color.tteBackground
                .overlay(Rectangle().fill(Color(UIColor.separator)).frame(height: 0.5), alignment: .top)
        )
    }

    // 답장 대상 미리보기 (입력창 위)
    private func replyPreview(_ reply: ChatMessage) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.tteOrange).frame(width: 3).cornerRadius(2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("chat.replyTo", reply.nickname))
                    .font(.tte(12, .semibold))
                    .foregroundColor(.tteOrange)
                Text(reply.text)
                    .font(.tte(12))
                    .foregroundColor(.tteMediumGray)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.tte(18))
                    .foregroundColor(.tteMediumGray.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft
        draft = ""
        chat.sendChat(text, replyTo: replyingTo)
        replyingTo = nil
    }

    // 답장 인용 블록 탭 → 원본 메시지로 스크롤 + 잠깐 하이라이트
    private func scrollToOriginal(of reply: ChatMessage) {
        guard let targetId = chat.originalMessageId(for: reply) else { return }
        scrollTargetId = targetId
        withAnimation { highlightedId = targetId }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if highlightedId == targetId { highlightedId = nil } }
        }
    }

    // MARK: - 피드 → 시스템 메시지 텍스트

    static func systemText(for item: FeedItem) -> String {
        switch item.type {
        case .tripStart:     return L("feed.tripStart", item.nickname, item.courseName)
        case .tripEnd:       return L("feed.tripEnd", item.nickname, item.courseName)
        case .arrival:       return L("feed.arrival", item.nickname, item.placeName ?? "")
        case .photo:         return L("feed.photo", item.nickname)
        case .freeTripStart: return L("feed.freeTripStart", item.nickname)
        case .freeCapture:   return L("feed.freeCapture", item.nickname, item.placeName ?? L("feed.here"))
        case .freeTripEnd:   return L("feed.freeTripEnd", item.nickname, item.courseName)
        }
    }
}

// MARK: - 말풍선

private struct ChatBubble: View {
    let message: ChatMessage
    let isMine: Bool
    let myUserId: String
    var quickEmojis: [String] = []
    var highlighted: Bool = false
    var onReply: () -> Void = {}
    var onReact: (String) -> Void = { _ in }
    var onQuoteTap: () -> Void = {}
    var onResend: () -> Void = {}

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine {
                    Text(message.nickname)
                        .font(.tte(11))
                        .foregroundColor(.tteMediumGray)
                        .padding(.leading, 4)
                }
                HStack(alignment: .bottom, spacing: 5) {
                    if isMine {
                        // 전송 실패 — 탭하면 재전송
                        if message.failed {
                            Button(action: onResend) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.tte(15))
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("chat.resend"))
                        }
                        timeLabel
                    }
                    bubbleBody
                    if !isMine { timeLabel }
                }
                reactionChips
            }
            if !isMine { Spacer(minLength: 40) }
        }
    }

    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 인용된 원본 (답장인 경우) — 탭하면 원본으로 이동
            if message.hasReply {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.replyToNickname ?? "")
                        .font(.tte(11, .semibold))
                        .foregroundColor(isMine ? .white.opacity(0.9) : .tteOrange)
                    Text(message.replyToText ?? "")
                        .font(.tte(12))
                        .foregroundColor(isMine ? .white.opacity(0.75) : .tteMediumGray)
                        .lineLimit(2)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isMine ? Color.white.opacity(0.18) : Color.black.opacity(0.05))
                )
                .padding(.bottom, 4)
                .contentShape(Rectangle())
                .onTapGesture { onQuoteTap() }
            }
            Text(message.text)
                .font(.tte(15))
                .foregroundColor(isMine ? .white : .tteDarkGray)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isMine ? Color.tteOrange.opacity(message.pending ? 0.55 : 1.0)
                             : Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.tteOrange, lineWidth: highlighted ? 2.5 : 0)
        )
        .contextMenu {
            ForEach(quickEmojis, id: \.self) { emoji in
                Button { onReact(emoji) } label: { Text("\(emoji)  \(L("chat.react"))") }
            }
            Divider()
            Button { onReply() } label: { Label(L("chat.reply"), systemImage: "arrowshape.turn.up.left") }
            Button { UIPasteboard.general.string = message.text } label: {
                Label(L("chat.copy"), systemImage: "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private var reactionChips: some View {
        let chips = message.reactionChips(myUserId: myUserId)
        if !chips.isEmpty {
            HStack(spacing: 4) {
                ForEach(chips, id: \.emoji) { chip in
                    Button { onReact(chip.emoji) } label: {
                        HStack(spacing: 3) {
                            Text(chip.emoji).font(.tte(12))
                            Text("\(chip.count)")
                                .font(.tte(11, .semibold))
                                .foregroundColor(chip.mine ? .tteOrange : .tteMediumGray)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(chip.mine ? Color.tteOrange.opacity(0.15)
                                                     : Color(UIColor.secondarySystemBackground))
                        )
                        .overlay(
                            Capsule().stroke(chip.mine ? Color.tteOrange.opacity(0.5) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 1)
        }
    }

    private var timeLabel: some View {
        Text(message.createdAt.formatted(date: .omitted, time: .shortened))
            .font(.tte(10))
            .foregroundColor(.tteMediumGray.opacity(0.7))
    }
}

// MARK: - 시스템(활동) 메시지

private struct SystemMessageRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.tte(12))
            .foregroundColor(.tteMediumGray)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(UIColor.secondarySystemBackground).opacity(0.7)))
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
