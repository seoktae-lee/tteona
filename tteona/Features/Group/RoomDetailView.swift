import SwiftUI
import MapKit

struct RoomDetailView: View {
    let room: Room
    var autoOpenUserId: String? = nil   // (구 댓글 스레드용 — 단톡 전환 후 미사용, 호환 위해 유지)
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @State private var showLeaveAlert = false
    @State private var showShareSheet = false

    private var uid: String { authService.currentUser?.uid ?? "" }

    private var roomInviteURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tteona.kr"
        components.path = "/room"
        components.queryItems = [
            URLQueryItem(name: "code", value: room.inviteCode),
            URLQueryItem(name: "name", value: room.name)
        ]
        return components.url ?? URL(string: "https://tteona.kr")!
    }

    var body: some View {
        VStack(spacing: 0) {
            inviteCodeBanner
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)

            Divider()

            GroupChatView(room: room)
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(room.name)
                    .font(.custom("GowunBatang-Regular", size: 20))
                    .foregroundColor(.tteDarkGray)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showLeaveAlert = true
                    } label: {
                        Label(L("room.leave"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.tteDarkGray)
                }
            }
        }
        .alert(L("room.leave"), isPresented: $showLeaveAlert) {
            Button(L("room.leaveButton"), role: .destructive) {
                Task { try? await roomService.leaveRoom(roomId: room.roomId, userId: uid) }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("room.leaveMessage"))
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [roomInviteURL])
        }
        .onAppear {
            Task { await roomService.fetchMembers(roomId: room.roomId) }
            roomService.startListeningFeed(roomId: room.roomId)
        }
        .onDisappear {
            roomService.stopListeningFeed()
        }
    }

    // MARK: - 초대코드 배너
    private var inviteCodeBanner: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("room.inviteCode"))
                    .font(.tte(11))
                    .foregroundColor(.tteMediumGray)
                Text(room.inviteCode)
                    .font(.tte(22, .bold))
                    .foregroundColor(.tteOrange)
                    .kerning(4)
            }
            Spacer()
            Button {
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.tte(15))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.tteOrange))
            }
            HStack(spacing: 3) {
                Image(systemName: "person.fill")
                    .font(.tte(11))
                    .foregroundColor(.tteMediumGray)
                Text(L("room.membersCount", room.memberIds.count))
                    .font(.tte(12))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
    }
}

// MARK: - 피드 카드
struct FeedCard: View {
    let item: FeedItem
    var onComment: (() -> Void)? = nil

    private var icon: String {
        switch item.type {
        case .tripStart:     return "🚀"
        case .tripEnd:       return "✅"
        case .arrival:       return "📍"
        case .photo:         return "📸"
        case .freeTripStart: return "🗺️"
        case .freeCapture:   return "📸"
        case .freeTripEnd:   return "✅"
        }
    }

    private var message: String {
        switch item.type {
        case .tripStart:     return L("feedcard.tripStart", item.nickname, item.courseName)
        case .tripEnd:       return L("feedcard.tripEnd", item.nickname, item.courseName)
        case .arrival:       return L("feedcard.arrival", item.nickname, item.placeName ?? "")
        case .photo:         return L("feedcard.photo", item.nickname)
        case .freeTripStart: return L("feedcard.freeTripStart", item.nickname)
        case .freeCapture:   return L("feedcard.freeCapture", item.nickname, item.placeName ?? L("feed.here"))
        case .freeTripEnd:   return L("feedcard.freeTripEnd", item.nickname, item.courseName)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(icon)
                .font(.tte(26))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.tteOrange.opacity(0.1)))

            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.tte(14, .medium))
                    .foregroundColor(.tteDarkGray)
                HStack(spacing: 6) {
                    Text(item.createdAt.relativeDescription)
                        .font(.tte(12))
                        .foregroundColor(.tteMediumGray)
                    if item.commentCount > 0 {
                        Text("·")
                            .foregroundColor(.tteMediumGray.opacity(0.5))
                            .font(.tte(12))
                        Text(L("feed.comments", item.commentCount))
                            .font(.tte(12))
                            .foregroundColor(.tteOrange.opacity(0.8))
                    }
                }
            }

            Spacer()

            Button {
                onComment?()
            } label: {
                Image(systemName: item.commentCount > 0 ? "bubble.left.fill" : "bubble.left")
                    .font(.tte(20))
                    .foregroundColor(item.commentCount > 0 ? .tteOrange : .tteMediumGray.opacity(0.5))
                    .frame(width: 40, height: 40)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemBackground)))
    }
}

// MARK: - 멤버 채팅방 행
struct MemberChatRow: View {
    let member: RoomMember
    let isMe: Bool
    let latestFeed: FeedItem?
    var hasNewFeed: Bool = false
    var isActive: Bool = false

    private var latestFeedSummary: String? {
        guard let feed = latestFeed else { return nil }
        let timeStr = feed.createdAt.relativeDescription
        let action: String
        switch feed.type {
        case .tripStart:     action = L("feedaction.tripStart", feed.courseName)
        case .tripEnd:       action = L("feedaction.tripEnd", feed.courseName)
        case .arrival:       action = L("feedaction.arrival", feed.placeName ?? "")
        case .photo:         action = L("feedaction.photo")
        case .freeTripStart: action = L("feedaction.freeTripStart")
        case .freeCapture:   action = L("feedaction.freeCapture", feed.placeName ?? L("feed.here"))
        case .freeTripEnd:   action = L("feedaction.freeTripEnd")
        }
        return "\(action) · \(timeStr)"
    }

    var body: some View {
        HStack(spacing: 16) {
            // 프로필 원형 이니셜 + dot
            ZStack {
                Circle()
                    .fill(Color.tteOrange.opacity(0.08))
                    .frame(width: 48, height: 48)
                Text(String(member.nickname.prefix(1)))
                    .font(.custom("GowunBatang-Regular", size: 20))
                    .foregroundColor(.tteOrange)
                // 활동 중 초록 dot (하단)
                if isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.tteBackground, lineWidth: 2))
                        .offset(x: 18, y: 18)
                }
                // 새 피드 주황 dot (상단)
                if hasNewFeed {
                    Circle()
                        .fill(Color.tteOrange)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.tteBackground, lineWidth: 2))
                        .offset(x: 18, y: -18)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isMe ? L("member.me", member.nickname) : member.nickname)
                    .font(.custom("GowunBatang-Regular", size: 19))
                    .foregroundColor(.tteDarkGray)
                if let summary = latestFeedSummary {
                    Text(summary)
                        .font(.tte(12))
                        .foregroundColor(.tteMediumGray)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.tte(12, .medium))
                .foregroundColor(.tteMediumGray.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.tteBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.tteOrange.opacity(0.4), lineWidth: 1.2)
        )
    }
}

struct FeedMember: Identifiable {
    let id: String
    let userId: String
    let nickname: String

    init(userId: String, nickname: String) {
        self.id = userId
        self.userId = userId
        self.nickname = nickname
    }
}
