import SwiftUI

struct FeedCommentView: View {
    let roomId: String
    let feedItem: FeedItem
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [FeedComment] = []
    @State private var commentText = ""
    @State private var isPosting = false
    @State private var isLoading = true
    @FocusState private var isInputFocused: Bool

    private var uid: String { authService.currentUser?.uid ?? "" }
    private var nickname: String { userService.currentUser?.nickname ?? "멤버" }

    private var feedMessage: String {
        switch feedItem.type {
        case .tripStart:     return "\(feedItem.nickname)님이 \(feedItem.courseName) 여행을 시작했어요! 🚀"
        case .arrival:       return "\(feedItem.nickname)님이 \(feedItem.placeName ?? "")에 도착했어요! 📍"
        case .photo:         return "\(feedItem.nickname)님이 사진을 공유했어요 📸"
        case .freeTripStart: return "\(feedItem.nickname)님이 나의 오늘을 시작했어요! 🗺️"
        case .freeCapture:   return "\(feedItem.nickname)님이 \(feedItem.placeName ?? "이곳")에서 영상을 남겼어요 📸"
        case .freeTripEnd:   return "\(feedItem.nickname)님의 오늘이 끝났어요! ✅"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                feedHeader
                Divider()
                commentList
                inputBar
            }
            .navigationTitle("댓글")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                        .foregroundColor(.tteDarkGray)
                }
            }
        }
        .task {
            comments = await roomService.fetchComments(roomId: roomId, feedId: feedItem.feedId)
            isLoading = false
        }
    }

    // MARK: - 피드 헤더
    private var feedHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.tteOrange.opacity(0.12))
                    .frame(width: 44, height: 44)
                Text(String(feedItem.nickname.prefix(1)))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.tteOrange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(feedMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.tteDarkGray)
                Text(feedItem.createdAt.relativeDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.tteMediumGray)
            }
            Spacer()
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemBackground))
    }

    // MARK: - 댓글 목록
    @ViewBuilder
    private var commentList: some View {
        if isLoading {
            Spacer()
            ProgressView().tint(.tteOrange)
            Spacer()
        } else if comments.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 36))
                    .foregroundColor(.tteMediumGray.opacity(0.4))
                Text("첫 댓글을 남겨보세요!")
                    .font(.system(size: 14))
                    .foregroundColor(.tteMediumGray)
            }
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(comments) { comment in
                            CommentRow(comment: comment, isMe: comment.userId == uid)
                                .id(comment.commentId)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: comments.count) { _, _ in
                    if let last = comments.last {
                        withAnimation { proxy.scrollTo(last.commentId, anchor: .bottom) }
                    }
                }
            }
        }
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
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.secondarySystemBackground)))

            Button {
                Task { await postComment() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(commentText.trimmingCharacters(in: .whitespaces).isEmpty ? .tteMediumGray.opacity(0.4) : .tteOrange)
            }
            .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty || isPosting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.tteBackground.shadow(color: .black.opacity(0.06), radius: 8, y: -2))
    }

    private func postComment() async {
        let text = commentText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isPosting = true
        commentText = ""
        do {
            try await roomService.addComment(roomId: roomId, feedId: feedItem.feedId, userId: uid, nickname: nickname, text: text)
            comments = await roomService.fetchComments(roomId: roomId, feedId: feedItem.feedId)
        } catch {}
        isPosting = false
    }
}

// MARK: - 댓글 행
struct CommentRow: View {
    let comment: FeedComment
    let isMe: Bool

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
                Text(comment.text)
                    .font(.system(size: 14))
                    .foregroundColor(isMe ? .white : .tteDarkGray)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isMe ? Color.tteOrange : Color(UIColor.secondarySystemBackground))
                    )
                Text(comment.createdAt.relativeDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.tteMediumGray.opacity(0.7))
            }

            if !isMe { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
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
