import SwiftUI
import MapKit

// 채팅 타임라인에서 피드 이벤트와 댓글을 통합하는 타입
enum ChatEntry: Identifiable {
    case feed(FeedItem)
    case comment(FeedComment)

    var id: String {
        switch self {
        case .feed(let f): return "feed_\(f.feedId)"
        case .comment(let c): return "comment_\(c.commentId)"
        }
    }

    var date: Date {
        switch self {
        case .feed(let f): return f.createdAt
        case .comment(let c): return c.createdAt
        }
    }
}

struct MemberChatView: View {
    let roomId: String
    let memberUserId: String
    let memberNickname: String

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ChatEntry] = []
    @State private var feedItems: [FeedItem] = []
    @State private var commentText = ""
    @State private var isLoading = true
    @State private var isPosting = false
    @State private var replyTarget: FeedComment? = nil
    @FocusState private var isInputFocused: Bool

    private var uid: String { authService.currentUser?.uid ?? "" }
    private var nickname: String { userService.currentUser?.nickname ?? "멤버" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    Spacer()
                    ProgressView().tint(.tteOrange)
                    Spacer()
                } else if entries.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 36))
                            .foregroundColor(.tteMediumGray.opacity(0.4))
                        Text("아직 활동이 없어요")
                            .font(.system(size: 14))
                            .foregroundColor(.tteMediumGray)
                    }
                    Spacer()
                } else {
                    chatList
                }
                if replyTarget != nil { replyBar }
                inputBar
            }
            .navigationTitle("\(memberNickname)님의 오늘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                        .foregroundColor(.tteDarkGray)
                }
            }
        }
        .onAppear {
            roomService.startListeningMemberFeed(roomId: roomId, userId: memberUserId) { items in
                feedItems = items
                Task { await rebuildEntries(feeds: items) }
            }
        }
        .onDisappear {
            roomService.stopListeningMemberFeed()
        }
    }

    // MARK: - 채팅 목록
    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .feed(let item):
                            FeedEventRow(item: item)
                                .id(entry.id)
                        case .comment(let comment):
                            CommentRow(comment: comment, isMe: comment.userId == uid) {
                                replyTarget = comment
                                isInputFocused = true
                            }
                            .id(entry.id)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: entries.count) { _, _ in
                guard let last = entries.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: - 답장 인용 바
    private var replyBar: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.tteOrange)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(replyTarget?.nickname ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.tteOrange)
                Text(replyTarget?.text ?? "")
                    .font(.system(size: 12))
                    .foregroundColor(.tteMediumGray)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                replyTarget = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.tteMediumGray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
    }

    // MARK: - 입력창
    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("댓글 달기...", text: $commentText, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($isInputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20)
                    .fill(Color(UIColor.secondarySystemBackground)))

            Button {
                Task { await postComment() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(commentText.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? .tteMediumGray.opacity(0.4) : .tteOrange)
            }
            .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty || isPosting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.tteBackground.shadow(color: .black.opacity(0.06), radius: 8, y: -2))
    }

    // MARK: - 엔트리 재빌드
    private func rebuildEntries(feeds: [FeedItem]) async {
        let feedIds = feeds.map(\.feedId)
        let commentsMap = await roomService.fetchAllCommentsForFeeds(roomId: roomId, feedIds: feedIds)
        var all: [ChatEntry] = []
        for feed in feeds {
            all.append(.feed(feed))
            let comments = commentsMap[feed.feedId] ?? []
            all.append(contentsOf: comments.map { .comment($0) })
        }
        all.sort { $0.date < $1.date }
        entries = all
        isLoading = false
    }

    private func postComment() async {
        let text = commentText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isPosting = true
        let reply = replyTarget
        commentText = ""
        replyTarget = nil
        do {
            try await roomService.addCommentToLatestFeed(
                roomId: roomId,
                userId: memberUserId,
                commenterId: uid,
                commenterNickname: nickname,
                text: text,
                replyToNickname: reply?.nickname,
                replyToText: reply?.text
            )
        } catch {
            print("[Comment] error: \(error)")
        }
        await rebuildEntries(feeds: feedItems)
        isPosting = false
    }
}

// MARK: - 피드 이벤트 행 (시스템 메시지 스타일)
struct FeedEventRow: View {
    let item: FeedItem

    private var icon: String {
        switch item.type {
        case .tripStart:     return "🚀"
        case .tripEnd:       return "✅"
        case .arrival:       return "📍"
        case .photo:         return "📸"
        case .freeTripStart: return ""
        case .freeCapture:   return "🎬"
        case .freeTripEnd:   return "✅"
        }
    }

    private var message: String {
        switch item.type {
        case .tripStart:     return "\(item.courseName) 여행을 시작했어요!"
        case .tripEnd:       return "\(item.courseName) 여행을 종료했어요!"
        case .arrival:       return "\(item.placeName ?? "")에 도착했어요!"
        case .photo:         return "사진을 공유했어요"
        case .freeTripStart: return "나의 오늘을 시작했어요!"
        case .freeCapture:   return "\(item.placeName ?? "이곳")에서 영상을 남겼어요"
        case .freeTripEnd:   return "오늘 \(item.courseName) 기록을 마쳤어요"
        }
    }

    var body: some View {
        if item.type == .freeCapture, let lat = item.latitude, let lon = item.longitude {
            // 지도 썸네일 카드
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            Button {
                openInMap(latitude: lat, longitude: lon, name: item.placeName ?? "영상 기록 장소")
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Map(position: .constant(.region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                    )))) {
                        Annotation("", coordinate: coord) {
                            ZStack {
                                Circle().fill(Color.tteOrange).frame(width: 28, height: 28)
                                Text("🎬").font(.system(size: 13))
                            }
                        }
                    }
                    .frame(height: 130)
                    .disabled(true)
                    .allowsHitTesting(false)

                    HStack(spacing: 6) {
                        Text("🎬")
                            .font(.system(size: 12))
                        Text(message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.tteDarkGray)
                        Spacer()
                        Text(item.createdAt.relativeDescription)
                            .font(.system(size: 11))
                            .foregroundColor(.tteMediumGray.opacity(0.7))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(UIColor.separator).opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 32)
            .padding(.vertical, 6)
        } else {
            // 기존 캡슐 스타일
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Text(icon)
                        .font(.system(size: 13))
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.tteMediumGray)
                    Text("·")
                        .foregroundColor(.tteMediumGray.opacity(0.5))
                    Text(item.createdAt.relativeDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.tteMediumGray.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(UIColor.tertiarySystemBackground)))
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
        }
    }

    private func openInMap(latitude: Double, longitude: Double, name: String) {
        let kakaoScheme = "kakaomap://look?p=\(latitude),\(longitude)"
        let appleURL = URL(string: "maps://?ll=\(latitude),\(longitude)&q=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!

        if let kakaoURL = URL(string: kakaoScheme), UIApplication.shared.canOpenURL(kakaoURL) {
            UIApplication.shared.open(kakaoURL)
        } else {
            UIApplication.shared.open(appleURL)
        }
    }
}

// MARK: - 댓글 행
struct CommentRow: View {
    let comment: FeedComment
    let isMe: Bool
    var onReply: (() -> Void)? = nil

    @State private var showReplyAction = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isMe { Spacer(minLength: 50) }

            if !isMe {
                ZStack {
                    Circle()
                        .fill(Color.tteMediumGray.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Text(String(comment.nickname.prefix(1)))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.tteDarkGray)
                }
            }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                if !isMe {
                    Text(comment.nickname)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.tteMediumGray)
                }

                // 말풍선 (인용 + 본문을 하나로)
                VStack(alignment: .leading, spacing: 0) {
                    // 인용 박스
                    if let rn = comment.replyToNickname, let rt = comment.replyToText {
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(isMe ? Color.white.opacity(0.7) : Color.tteOrange)
                                .frame(width: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rn)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(isMe ? .white : .tteOrange)
                                Text(rt)
                                    .font(.system(size: 11))
                                    .foregroundColor(isMe ? .white.opacity(0.8) : .tteMediumGray)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                        .background(isMe ? Color.white.opacity(0.15) : Color.black.opacity(0.05))

                        Divider()
                            .background(isMe ? Color.white.opacity(0.3) : Color.black.opacity(0.08))
                    }

                    // 본문
                    Text(comment.text)
                        .font(.system(size: 14))
                        .foregroundColor(isMe ? .white : .tteDarkGray)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isMe ? Color.tteOrange : Color(UIColor.secondarySystemBackground))
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .onLongPressGesture {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showReplyAction = true
                }
                .confirmationDialog("", isPresented: $showReplyAction) {
                    Button("↩ 답장") { onReply?() }
                    Button("취소", role: .cancel) {}
                }

                Text(comment.createdAt.relativeDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.tteMediumGray.opacity(0.7))
            }

            if !isMe { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

extension Date {
    var relativeDescription: String {
        let diff = Int(Date().timeIntervalSince(self))
        if diff < 60 { return "방금 전" }
        if diff < 3600 { return "\(diff / 60)분 전" }
        if diff < 86400 { return "\(diff / 3600)시간 전" }
        return "\(diff / 86400)일 전"
    }
}
