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
    @State private var showNavGuide = false

    // 내비게이션 가이드는 계정별로 1회 표시 (온보딩이 계정별인 것과 일관되게)
    private var navGuideSeenKey: String? {
        authService.currentUser.map { "hasSeenNavGuide_\($0.uid)" }
    }

    private var hasSeenNavGuide: Bool {
        guard let key = navGuideSeenKey else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    var body: some View {
        ZStack {
            tabContent

            if showNavGuide {
                NavGuideOverlay(selectedTab: $selectedTab) {
                    if let key = navGuideSeenKey {
                        UserDefaults.standard.set(true, forKey: key)
                    }
                    withAnimation(.easeOut(duration: 0.25)) { showNavGuide = false }
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
    }

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            MainView()
                .tabItem {
                    Label(L("tab.home"), systemImage: "map.fill")
                }
                .tag(0)

            ExploreGridView()
                .tabItem {
                    Label(L("tab.explore"), systemImage: "square.grid.2x2.fill")
                }
                .tag(1)

            FeedTabView()
                .tabItem {
                    Label(L("tab.chat"), systemImage: "bubble.left.and.bubble.right.fill")
                }
                .badge(roomService.unreadRoomIds.count)
                .tag(2)

            SettingsView()
                .tabItem {
                    Label(L("tab.settings"), systemImage: "gearshape.fill")
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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-previewNavGuide") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeIn(duration: 0.3)) { showNavGuide = true }
                }
            }
            #endif
            // 첫 진입 시 나루 내비게이션 가이드 (딥링크 진입 시에는 방해하지 않음)
            if !hasSeenNavGuide,
               deepLinkHandler.pendingCourseId == nil,
               deepLinkHandler.pendingRoomCode == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard !hasSeenNavGuide else { return }
                    withAnimation(.easeIn(duration: 0.3)) { showNavGuide = true }
                }
            }
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
