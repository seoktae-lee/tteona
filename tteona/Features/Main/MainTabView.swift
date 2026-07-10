import SwiftUI

/// fullScreenCover(item:)에 쓰려면 Identifiable이 필요하다 — URL은 그렇지 않다.
private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

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
    @State private var notificationVlogURL: IdentifiedURL? = nil

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
            routedTabContent

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

    /// 알림 탭 라우팅 — tabContent의 모디파이어 체인에 그대로 이어 붙이면
    /// 타입체커가 감당하지 못해(unable to type-check in reasonable time) 분리해 둔다.
    private var routedTabContent: some View {
        tabContent
            // 좋아요·코스 따라가기 알림 탭 → 딥링크와 같은 경로로 코스 상세를 연다
            .onChange(of: notificationManager.pendingCourseId) { _, courseId in
                guard let courseId else { return }
                notificationManager.pendingCourseId = nil
                deepLinkTask?.cancel()
                deepLinkTask = Task {
                    deepLinkedCourse = try? await courseService.fetchCourse(by: courseId)
                }
            }
            // 주간 리포트 알림 탭 → 프로필 탭(여행 통계)
            .onChange(of: notificationManager.shouldOpenProfile) { _, should in
                guard should else { return }
                notificationManager.shouldOpenProfile = false
                selectedTab = 3
            }
            // Vlog 완성 알림 탭 → 서버가 보내준 완성본을 바로 재생
            .onChange(of: notificationManager.pendingVlogURL) { _, url in
                guard let url else { return }
                notificationManager.pendingVlogURL = nil
                notificationVlogURL = IdentifiedURL(url: url)
            }
            .fullScreenCover(item: $notificationVlogURL) { item in
                VlogPreviewView(vlogURL: item.url) {
                    notificationVlogURL = nil
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

            ProfileTabView()
                .tabItem {
                    Label(L("tab.profile"), systemImage: "person.crop.circle.fill")
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
            // 시각 검증용: 프로필 탭 바로 진입
            if ProcessInfo.processInfo.arguments.contains("-previewProfileTab") {
                selectedTab = 3
            }
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
