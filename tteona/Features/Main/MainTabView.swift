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
    /// 탭 인덱스를 숫자로 흩어 두면 탭이 하나 늘 때마다 알림 라우팅이 조용히 어긋난다.
    /// 여기서만 정의하고 전부 이걸 참조한다.
    enum Tab {
        static let capture  = 0
        static let discover = 1
        static let chat     = 2
        static let profile  = 3
    }

    @State private var selectedTab: Int = Tab.capture
    /// 촬영 중 여부 — 탭바를 숨기는 데 쓴다
    @State private var isRecordingClip = false
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
                    // 내비 가이드가 끝나면 바로 첫 브이로그 튜토리얼로 이어간다
                    if let uid = authService.currentUser?.uid {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            VlogTutorial.shared.beginIfNeeded(uid: uid)
                        }
                    }
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
            // 좋아요·코스 따라가기(코스 상세), 주간 리포트(프로필), Vlog 완성(재생) 알림 탭.
            // 앱이 실행 중일 때는 이 onChange들이, 콜드 스타트 때는 아래 onAppear가 소비한다.
            .onChange(of: notificationManager.pendingCourseId) { _, id in
                if id != nil { consumeNotificationRouting() }
            }
            .onChange(of: notificationManager.shouldOpenProfile) { _, should in
                if should { consumeNotificationRouting() }
            }
            .onChange(of: notificationManager.pendingVlogURL) { _, url in
                if url != nil { consumeNotificationRouting() }
            }
            .fullScreenCover(item: $notificationVlogURL) { item in
                VlogPreviewView(vlogURL: item.url) {
                    notificationVlogURL = nil
                }
            }
            // 콜드 스타트: 앱이 꺼진 상태에서 알림을 탭하면 목적지가 뷰 생성 전에 정해져
            // onChange가 "변화"를 못 보고 지나친다. 진입 시 한 번 직접 소비한다.
            .onAppear { consumeNotificationRouting() }
    }

    /// 알림 탭으로 정해진 목적지를 소비한다. onChange(실행 중 탭)와 onAppear(콜드 스타트)가
    /// 함께 호출하며, 어느 쪽이 먼저든 값이 있을 때 한 번만 처리된다.
    private func consumeNotificationRouting() {
        if let courseId = notificationManager.pendingCourseId {
            notificationManager.pendingCourseId = nil
            deepLinkTask?.cancel()
            deepLinkTask = Task {
                deepLinkedCourse = try? await courseService.fetchCourse(by: courseId)
            }
        }
        if let url = notificationManager.pendingVlogURL {
            notificationManager.pendingVlogURL = nil
            notificationVlogURL = IdentifiedURL(url: url)
        }
        if notificationManager.shouldOpenProfile {
            notificationManager.shouldOpenProfile = false
            selectedTab = Tab.profile
        }
    }

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            // 앱의 1번 기능 — 켜자마자 뷰파인더가 보이도록 기본 탭으로 둔다
            CaptureTabView(isRecording: $isRecordingClip)
                .tabItem {
                    Label(L("tab.capture"), systemImage: "camera.fill")
                }
                .tag(Tab.capture)

            // 지도 + 탐색 — 둘 다 "코스를 찾는" 화면이라 한 탭에 묶고 토글로 전환한다
            DiscoverTab()
                .tabItem {
                    Label(L("tab.discover"), systemImage: "map.fill")
                }
                .tag(Tab.discover)

            ChatTab()
                .tabItem {
                    Label(L("tab.chat"), systemImage: "bubble.left.and.bubble.right.fill")
                }
                .badge(roomService.unreadRoomIds.count)
                .tag(Tab.chat)

            ProfileTab()
                .tabItem {
                    Label(L("tab.profile"), systemImage: "person.crop.circle.fill")
                }
                .tag(Tab.profile)
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

            // 발견 탭을 누르기 전에 지도와 코스를 미리 준비한다.
            //
            // 지도가 첫 탭이던 시절엔 이 둘이 앱 실행 중에 이미 끝나 있어서 핀이 바로 보였다.
            // 촬영 탭이 첫 화면이 되며 준비가 '발견을 누른 순간'으로 밀렸고, 그 대기가
            // 고스란히 노출됐다. 화면 순서는 그대로 두고 준비 시점만 예전으로 되돌린다.
            //
            // 차단 목록을 받은 뒤에 조회해야 차단한 사용자의 코스가 잠깐이라도 뜨지 않는다.
            MapWarmUp.run()
            await courseService.fetchCourses(
                blockedUserIds: userService.currentUser?.blockedUserIds ?? []
            )
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
                roomService.stopListeningFeed()
                roomService.stopListeningMemberFeed()
                return
            }
            roomService.startListeningMyRooms(userId: uid)
        }
        .onChange(of: notificationManager.pendingChatRoom) { _, pending in
            guard pending != nil else { return }
            selectedTab = Tab.chat
        }
        .onAppear {
            #if DEBUG
            // 시각 검증용: 프로필 탭 바로 진입
            if ProcessInfo.processInfo.arguments.contains("-previewProfileTab") {
                selectedTab = Tab.profile
            }
            if ProcessInfo.processInfo.arguments.contains("-previewNavGuide") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeIn(duration: 0.3)) { showNavGuide = true }
                }
            }
            // 시각 검증용: 완료 플래그를 지우고 브이로그 튜토리얼 즉시 시작
            if ProcessInfo.processInfo.arguments.contains("-previewVlogTutorial") {
                let uid = authService.currentUser?.uid ?? "preview"
                UserDefaults.standard.removeObject(forKey: "vlogTutorialDone_\(uid)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    VlogTutorial.shared.beginIfNeeded(uid: uid)
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
            } else if hasSeenNavGuide,
                      deepLinkHandler.pendingCourseId == nil,
                      deepLinkHandler.pendingRoomCode == nil,
                      let uid = authService.currentUser?.uid {
                // 내비 가이드는 이미 봤지만 첫 브이로그를 아직 안 만든 계정(기존 유저 포함)도
                // 한 번은 안내한다 — 말풍선은 터치를 막지 않고 X로 영구 종료 가능.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    VlogTutorial.shared.beginIfNeeded(uid: uid)
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


// MARK: - 게스트 게이팅 래퍼
//
// TabView의 자식을 `Group { if ... }`로 감싸면 조건에 따라 타입이 달라지는 뷰가 되고,
// 거기에 .tag()를 붙이면 SwiftUI 갱신 사이클이 깨진다(AttributeGraph cycle).
// 지도 마커가 갱신되지 않고 상단 필터 버튼이 먹통이 된 원인이 이것이었다.
// 탭의 자식은 항상 같은 타입으로 두고, 분기는 그 안에서 한다.

private struct DiscoverTab: View {
    @EnvironmentObject private var authService: AuthService
    var body: some View {
        if authService.isLoggedIn {
            DiscoverTabView()
        } else {
            GuestGateView(icon: "map.fill",
                          title: L("guest.discover.title"),
                          message: L("guest.discover.message"))
        }
    }
}

private struct ChatTab: View {
    @EnvironmentObject private var authService: AuthService
    var body: some View {
        if authService.isLoggedIn {
            FeedTabView()
        } else {
            GuestGateView(icon: "bubble.left.and.bubble.right.fill",
                          title: L("guest.chat.title"),
                          message: L("guest.chat.message"))
        }
    }
}

private struct ProfileTab: View {
    @EnvironmentObject private var authService: AuthService
    var body: some View {
        if authService.isLoggedIn {
            ProfileTabView()
        } else {
            GuestGateView(icon: "person.crop.circle.fill",
                          title: L("guest.profile.title"),
                          message: L("guest.profile.message"))
        }
    }
}
