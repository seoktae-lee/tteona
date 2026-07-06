import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var deepLinkHandler: DeepLinkHandler
    @EnvironmentObject private var notificationManager: AppNotificationManager
    @StateObject private var userService = UserService()
    @StateObject private var roomService = RoomService()
    @State private var deepLinkedCourse: Course? = nil
    @State private var deepLinkedRoomCode: String? = nil
    @State private var showJoinRoomFromDeepLink = false
    @State private var courseSessionInfo: CourseSessionInfo? = nil
    @State private var pendingSessionInfo: CourseSessionInfo? = nil
    @State private var selectedTab: Int = 0
    @State private var deepLinkTask: Task<Void, Never>? = nil

    var body: some View {
        TabView(selection: $selectedTab) {
            MainView()
                .tabItem {
                    Label("홈", systemImage: "map.fill")
                }
                .tag(0)

            ExploreGridView()
                .tabItem {
                    Label("탐색", systemImage: "square.grid.2x2.fill")
                }
                .tag(1)

            FeedTabView()
                .tabItem {
                    Label("채팅", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .badge(roomService.unreadRoomIds.count)
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("설정", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .tint(.tteOrange)
        .environmentObject(userService)
        .environmentObject(roomService)
        .sheet(item: $deepLinkedCourse, onDismiss: {
            // 딥링크 상세에서 "떠나기" 확정 시 → 시트 닫힘 완료 후 세션 시작
            if let info = pendingSessionInfo {
                pendingSessionInfo = nil
                courseSessionInfo = info
            }
        }) { course in
            CourseDetailView(course: course) { roomIds in
                pendingSessionInfo = CourseSessionInfo(course: course, roomIds: roomIds)
                deepLinkedCourse = nil
            }
            .environmentObject(authService)
            .environmentObject(courseService)
            .environmentObject(userService)
            .environmentObject(roomService)
        }
        .fullScreenCover(item: $courseSessionInfo) { info in
            ActiveSessionView(course: info.course, roomIds: info.roomIds)
                .environmentObject(AppNotificationManager.shared)
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .sheet(isPresented: $showJoinRoomFromDeepLink) {
            JoinRoomView(initialCode: deepLinkedRoomCode ?? "")
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .task {
            if let uid = authService.currentUser?.uid {
                await userService.fetchUser(uid: uid)
                roomService.blockedUserIds = Set(userService.currentUser?.blockedUserIds ?? [])
                roomService.startListeningMyRooms(userId: uid)
            }
        }
        .onChange(of: userService.currentUser?.blockedUserIds) { _, blocked in
            // 차단/해제 즉시 피드·댓글 필터에 반영
            roomService.blockedUserIds = Set(blocked ?? [])
        }
        .onChange(of: roomService.myRooms) { _, _ in
            guard let uid = authService.currentUser?.uid else { return }
            Task { await roomService.refreshUnreadStatus(userId: uid) }
        }
        .onChange(of: authService.currentUser?.uid) { _, uid in
            // 로그인/로그아웃 전환 시 실시간 리스너가 남지 않도록 정리
            guard let uid else {
                roomService.stopListeningMyRooms()
                roomService.stopListeningLocations()
                roomService.stopListeningFeed()
                roomService.stopListeningMemberFeed()
                return
            }
            roomService.startListeningMyRooms(userId: uid)
        }
        .onChange(of: notificationManager.pendingChatRoom) { _, pending in
            guard pending != nil else { return }
            selectedTab = 2
        }
        .onAppear {
            // 콜드 스타트 딥링크: MainTabView 진입 전 이미 pendingCourseId가 설정된 경우
            guard let courseId = deepLinkHandler.pendingCourseId else { return }
            deepLinkTask?.cancel()
            deepLinkTask = Task {
                deepLinkedCourse = try? await courseService.fetchCourse(by: courseId)
                deepLinkHandler.clearPendingCourse()
            }
        }
        .onChange(of: deepLinkHandler.pendingCourseId) { _, courseId in
            guard let courseId else { return }
            deepLinkTask?.cancel()
            deepLinkTask = Task {
                deepLinkedCourse = try? await courseService.fetchCourse(by: courseId)
                deepLinkHandler.clearPendingCourse()
            }
        }
        .onDisappear {
            deepLinkTask?.cancel()
            roomService.stopListeningMyRooms()
        }
        .onChange(of: deepLinkHandler.pendingRoomCode) { _, code in
            guard let code else { return }
            deepLinkedRoomCode = code
            showJoinRoomFromDeepLink = true
            deepLinkHandler.clearPendingRoom()
        }
    }
}
