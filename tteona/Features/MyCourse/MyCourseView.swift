import SwiftUI

struct MyCourseView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var roomService: RoomService
    @State private var selectedTab: MyCourseTab = .liked
    @State private var selectedCourse: Course?
    @State private var courseToDelete: Course?
    @State private var showDeleteConfirm = false

    enum MyCourseTab: String, CaseIterable {
        case liked = "좋아요"
        case mine = "내 코스"
        case group = "그룹"
    }

    private var likedCourses: [Course] {
        courseService.likedCourseIds.compactMap { id in
            courseService.courses.first { $0.courseId == id }
        }
    }

    private var myCourses: [Course] {
        courseService.courses.filter { $0.authorId == authService.currentUser?.uid }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker
                tabContent
            }
            .navigationTitle("나의 코스")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if selectedTab == .group {
                    ToolbarItem(placement: .topBarTrailing) {
                        groupToolbarMenu
                    }
                }
            }
        }
        .sheet(item: $selectedCourse) { course in
            CourseDetailView(course: course)
                .environmentObject(authService)
                .environmentObject(courseService)
                .environmentObject(UserService())
        }
        .alert("코스를 삭제할까요?", isPresented: $showDeleteConfirm) {
            Button("삭제", role: .destructive) {
                guard let course = courseToDelete else { return }
                Task {
                    try? await courseService.deleteCourse(course)
                    courseToDelete = nil
                }
            }
            Button("취소", role: .cancel) { courseToDelete = nil }
        } message: {
            Text("삭제하면 복구할 수 없어요.")
        }
        .task {
            if let uid = authService.currentUser?.uid {
                await courseService.fetchLikedCourseIds(userId: uid)
                roomService.startListeningMyRooms(userId: uid)
            }
        }
        .onDisappear {
            roomService.stopListeningMyRooms()
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(MyCourseTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 8) {
                        Text(tab.rawValue)
                            .font(.system(size: 15, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundColor(selectedTab == tab ? .tteDarkGray : .tteMediumGray)
                        Rectangle()
                            .fill(selectedTab == tab ? Color.tteOrange : Color.clear)
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
        .background(Color.tteBackground)
        .overlay(
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .liked, .mine:
            courseList
        case .group:
            GroupRoomList()
                .environmentObject(authService)
                .environmentObject(courseService)
                .environmentObject(roomService)
        }
    }

    @ViewBuilder
    private var courseList: some View {
        let courses = selectedTab == .liked ? likedCourses : myCourses
        let isMine = selectedTab == .mine

        if courses.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(courses) { course in
                        CourseListRow(course: course)
                            .onTapGesture { selectedCourse = course }
                            .contextMenu(isMine ? ContextMenu {
                                Button(role: .destructive) {
                                    courseToDelete = course
                                    showDeleteConfirm = true
                                } label: {
                                    Label("삭제", systemImage: "trash")
                                }
                            } : nil)
                    }
                }
                .padding(20)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: selectedTab == .liked ? "heart.slash" : "map.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.tteMediumGray.opacity(0.5))
            Text(selectedTab == .liked ? "좋아요한 코스가 없어요" : "아직 만든 코스가 없어요")
                .font(.system(size: 16))
                .foregroundColor(.tteMediumGray)
            Spacer()
        }
    }

    private var groupToolbarMenu: some View {
        GroupToolbarMenu()
            .environmentObject(authService)
            .environmentObject(roomService)
    }
}

// MARK: - GroupRoomList (그룹 탭 내용)
struct GroupRoomList: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @State private var showCreateRoom = false
    @State private var showJoinRoom = false
    @State private var selectedRoom: Room?

    var body: some View {
        Group {
            if roomService.myRooms.isEmpty {
                groupEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(roomService.myRooms) { room in
                            RoomCard(room: room)
                                .onTapGesture { selectedRoom = room }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationDestination(item: $selectedRoom) { room in
            RoomDetailView(room: room)
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .sheet(isPresented: $showCreateRoom) {
            CreateRoomView()
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .sheet(isPresented: $showJoinRoom) {
            JoinRoomView()
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCreateRoom)) { _ in showCreateRoom = true }
        .onReceive(NotificationCenter.default.publisher(for: .showJoinRoom)) { _ in showJoinRoom = true }
    }

    private var groupEmptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.3.fill")
                .font(.system(size: 52))
                .foregroundColor(.tteOrange.opacity(0.4))
            Text("아직 참여한 그룹이 없어요")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.tteDarkGray)
            Text("친구들과 함께 여행 코스를 공유하고\n투표로 최종 코스를 정해보세요!")
                .font(.system(size: 14))
                .foregroundColor(.tteMediumGray)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { showCreateRoom = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("방 만들기").fontWeight(.semibold)
                    }
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .frame(height: 48).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.tteOrange))
                }
                Button { showJoinRoom = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "key.horizontal.fill")
                        Text("코드 입력").fontWeight(.semibold)
                    }
                    .font(.system(size: 15))
                    .foregroundColor(.tteOrange)
                    .frame(height: 48).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).stroke(Color.tteOrange, lineWidth: 1.5))
                }
            }
            .padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - 툴바 메뉴 (그룹 탭일 때)
struct GroupToolbarMenu: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var roomService: RoomService

    var body: some View {
        Menu {
            Button {
                NotificationCenter.default.post(name: .showCreateRoom, object: nil)
            } label: {
                Label("방 만들기", systemImage: "plus.circle")
            }
            Button {
                NotificationCenter.default.post(name: .showJoinRoom, object: nil)
            } label: {
                Label("코드로 참여", systemImage: "key.horizontal")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.tteOrange)
        }
    }
}

extension Notification.Name {
    static let showCreateRoom = Notification.Name("showCreateRoom")
    static let showJoinRoom = Notification.Name("showJoinRoom")
}

struct CourseListRow: View {
    let course: Course

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(course.tag.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.tteOrange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.tteOrange.opacity(0.12)))

                Text(course.region)
                    .font(.system(size: 12))
                    .foregroundColor(.tteMediumGray)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(UIColor.tertiarySystemBackground)))

                Spacer()

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red.opacity(0.8))
                            .font(.system(size: 12))
                        Text("\(course.likeCount)")
                            .font(.system(size: 12))
                            .foregroundColor(.tteMediumGray)
                    }

                    Button {
                        CourseShareHelper.share(course: course)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.tteMediumGray)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(course.courseName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.tteDarkGray)

            HStack(spacing: 4) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.tteMediumGray)
                    .font(.system(size: 13))
                Text(course.places.map(\.placeName).joined(separator: " → "))
                    .font(.system(size: 13))
                    .foregroundColor(.tteMediumGray)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}
