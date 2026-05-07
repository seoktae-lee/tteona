import SwiftUI
import MapKit

struct RoomDetailView: View {
    let room: Room
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @State private var showLeaveAlert = false
    @State private var selectedFeedMember: FeedMember?
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
                .padding(.bottom, 8)

            VStack(spacing: 8) {
                Text("피드")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.tteDarkGray)
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.tteOrange)
                    .frame(height: 2)
            }
            .background(Color.tteBackground)
            .overlay(Rectangle().fill(Color(UIColor.separator)).frame(height: 1), alignment: .bottom)

            feedTab
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showLeaveAlert = true
                    } label: {
                        Label("그룹 나가기", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.tteDarkGray)
                }
            }
        }
        .sheet(item: $selectedFeedMember) { member in
            MemberChatView(roomId: room.roomId, memberUserId: member.userId, memberNickname: member.nickname)
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .alert("그룹 나가기", isPresented: $showLeaveAlert) {
            Button("나가기", role: .destructive) {
                Task { try? await roomService.leaveRoom(roomId: room.roomId, userId: uid) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("그룹을 나가면 다시 초대 코드로 참여할 수 있어요.")
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [roomInviteURL])
        }
        .onAppear {
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
                Text("초대 코드")
                    .font(.system(size: 11))
                    .foregroundColor(.tteMediumGray)
                Text(room.inviteCode)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.tteOrange)
                    .kerning(4)
            }
            Spacer()
            Button {
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.tteOrange))
            }
            HStack(spacing: 3) {
                Image(systemName: "person.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.tteMediumGray)
                Text("\(room.memberIds.count)명")
                    .font(.system(size: 12))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
    }

    // MARK: - 피드 탭
    private var feedTab: some View {
        Group {
            if roomService.feedItems.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "newspaper")
                        .font(.system(size: 44))
                        .foregroundColor(.tteOrange.opacity(0.35))
                    Text("아직 활동이 없어요\n코스로 여행을 시작하면 피드가 올라와요!")
                        .font(.system(size: 14))
                        .foregroundColor(.tteMediumGray)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(roomService.feedItems) { item in
                            FeedCard(item: item) {
                                selectedFeedMember = FeedMember(userId: item.userId, nickname: item.nickname)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

}

// MARK: - 피드 카드
struct FeedCard: View {
    let item: FeedItem
    var onComment: (() -> Void)? = nil

    private var icon: String {
        switch item.type {
        case .tripStart:     return "🚀"
        case .arrival:       return "📍"
        case .photo:         return "📸"
        case .freeTripStart: return "🗺️"
        case .freeCapture:   return "📸"
        case .freeTripEnd:   return "✅"
        }
    }

    private var message: String {
        switch item.type {
        case .tripStart:     return "\(item.nickname)님이 \(item.courseName) 여행을 시작했어요!"
        case .arrival:       return "\(item.nickname)님이 \(item.placeName ?? "")에 도착했어요!"
        case .photo:         return "\(item.nickname)님이 사진을 공유했어요"
        case .freeTripStart: return "\(item.nickname)님이 나의 오늘을 시작했어요!"
        case .freeCapture:   return "\(item.nickname)님이 \(item.placeName ?? "이곳")에서 영상을 남겼어요"
        case .freeTripEnd:   return "\(item.nickname)님의 오늘이 끝났어요!\n\(item.courseName)"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(icon)
                .font(.system(size: 26))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.tteOrange.opacity(0.1)))

            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.tteDarkGray)
                HStack(spacing: 6) {
                    Text(item.createdAt.relativeDescription)
                        .font(.system(size: 12))
                        .foregroundColor(.tteMediumGray)
                    if item.commentCount > 0 {
                        Text("·")
                            .foregroundColor(.tteMediumGray.opacity(0.5))
                            .font(.system(size: 12))
                        Text("댓글 \(item.commentCount)개")
                            .font(.system(size: 12))
                            .foregroundColor(.tteOrange.opacity(0.8))
                    }
                }
            }

            Spacer()

            Button {
                onComment?()
            } label: {
                Image(systemName: item.commentCount > 0 ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: 20))
                    .foregroundColor(item.commentCount > 0 ? .tteOrange : .tteMediumGray.opacity(0.5))
                    .frame(width: 40, height: 40)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemBackground)))
    }
}

// MARK: - Share Course View
struct ShareCourseView: View {
    let room: Room
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss
    @State private var isSharing = false

    private var myCourses: [Course] {
        courseService.courses.filter { $0.authorId == authService.currentUser?.uid }
    }

    var body: some View {
        NavigationStack {
            Group {
                if myCourses.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "map.badge.plus")
                            .font(.system(size: 48))
                            .foregroundColor(.tteMediumGray.opacity(0.4))
                        Text("공유할 코스가 없어요\n먼저 코스를 만들어보세요!")
                            .font(.system(size: 15))
                            .foregroundColor(.tteMediumGray)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(myCourses) { course in
                                CourseListRow(course: course)
                                    .onTapGesture {
                                        guard !isSharing else { return }
                                        isSharing = true
                                        Task {
                                            let nickname = userService.currentUser?.nickname ?? "멤버"
                                            let uid = authService.currentUser?.uid ?? ""
                                            try? await roomService.shareCourse(course, roomId: room.roomId, userId: uid, nickname: nickname)
                                            dismiss()
                                        }
                                    }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("코스 공유")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismiss() }.foregroundColor(.tteDarkGray)
                }
            }
        }
    }
}

// MARK: - Shared Course Card
struct SharedCourseCard: View {
    let shared: SharedCourse
    let isVoted: Bool
    let onVote: () -> Void
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(shared.tag.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.tteOrange)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.tteOrange.opacity(0.12)))
                Text(shared.region)
                    .font(.system(size: 12))
                    .foregroundColor(.tteMediumGray)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color(UIColor.tertiarySystemBackground)))
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11)).foregroundColor(.tteMediumGray)
                    Text(shared.sharedByNickname)
                        .font(.system(size: 12)).foregroundColor(.tteMediumGray)
                }
            }

            Text(shared.courseName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.tteDarkGray)

            HStack(spacing: 4) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.tteMediumGray).font(.system(size: 13))
                Text(shared.places.map(\.placeName).joined(separator: " → "))
                    .font(.system(size: 13)).foregroundColor(.tteMediumGray).lineLimit(1)
            }

            HStack(spacing: 10) {
                Button(action: onVote) {
                    HStack(spacing: 6) {
                        Image(systemName: isVoted ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.system(size: 14))
                        Text("\(shared.voteCount)")
                            .font(.system(size: 14, weight: .semibold))
                        Text("투표").font(.system(size: 14))
                    }
                    .foregroundColor(isVoted ? .white : .tteOrange)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(isVoted ? Color.tteOrange : Color.tteOrange.opacity(0.1)))
                }
                Button(action: onStart) {
                    HStack(spacing: 6) {
                        Image(systemName: "figure.walk").font(.system(size: 14))
                        Text("이 코스로 떠나기").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.tteDarkGray))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemBackground)))
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
