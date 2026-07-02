import SwiftUI
import CoreLocation

struct ExploreGridView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var notificationManager: AppNotificationManager

    enum SortMode: String, CaseIterable {
        case recommended = "추천순"
        case latest = "최신순"
        case popular = "인기순"
    }

    @StateObject private var locationService = LocationService()
    @State private var sortMode: SortMode = .recommended
    @State private var thumbnails: [String: String] = [:]
    @State private var recommendedIds: [String] = []
    @State private var isLoading = false
    @State private var selectedCourse: Course?
    @State private var showGroups = false
    @State private var courseSessionInfo: CourseSessionInfo?
    @State private var didRefetchWithLocation = false

    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
    ]

    private var sortedCourses: [Course] {
        let base = courseService.courses
        switch sortMode {
        case .latest:
            return base.sorted { $0.createdAt > $1.createdAt }
        case .popular:
            return base.sorted { $0.likeCount > $1.likeCount }
        case .recommended:
            guard !recommendedIds.isEmpty else { return base.sorted { $0.likeCount > $1.likeCount } }
            let map = Dictionary(uniqueKeysWithValues: base.map { ($0.courseId, $0) })
            let ranked = recommendedIds.compactMap { map[$0] }
            let rest = base.filter { c in !recommendedIds.contains(c.courseId) }
            return ranked + rest
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sortChips
                if isLoading && courseService.courses.isEmpty {
                    Spacer()
                    ProgressView().tint(.tteOrange)
                    Spacer()
                } else if sortedCourses.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(sortedCourses) { course in
                                GridCell(course: course, thumbnailURL: thumbnails[course.courseId])
                                    .onTapGesture { selectedCourse = course }
                            }
                        }
                    }
                }
            }
            .navigationTitle("탐색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showGroups = true
                    } label: {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.tteOrange)
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedCourse) { course in
            ExploreDetailView(course: course, thumbnailURL: thumbnails[course.courseId]) { roomIds in
                selectedCourse = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    courseSessionInfo = CourseSessionInfo(course: course, roomIds: roomIds)
                }
            }
            .environmentObject(authService)
            .environmentObject(courseService)
            .environmentObject(userService)
            .environmentObject(roomService)
        }
        .task {
            locationService.requestPermission()
            locationService.startTracking(places: [])
            await loadAll()
        }
        .refreshable { await loadAll() }
        .onChange(of: locationService.currentLocation) { _, loc in
            // 위치를 처음 확보하면 위치 기반으로 추천 1회 재조회
            guard !didRefetchWithLocation, loc != nil else { return }
            didRefetchWithLocation = true
            Task { await refetchRecommendations() }
        }
        .onAppear {
            // 채팅 푸시로 진입 시 그룹 시트 자동 오픈
            if notificationManager.pendingChatRoom != nil { showGroups = true }
        }
        .onChange(of: notificationManager.pendingChatRoom) { _, pending in
            if pending != nil { showGroups = true }
        }
        .sheet(isPresented: $showGroups) {
            FeedTabView()
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
                .environmentObject(notificationManager)
        }
        .fullScreenCover(item: $courseSessionInfo) { info in
            ActiveSessionView(course: info.course, roomIds: info.roomIds)
                .environmentObject(AppNotificationManager.shared)
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
    }

    // MARK: - Sort chips

    private var sortChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { sortMode = mode }
                    } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(sortMode == mode ? .white : .tteMediumGray)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(sortMode == mode ? Color.tteOrange : Color(UIColor.secondarySystemBackground))
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 44))
                .foregroundColor(.tteOrange.opacity(0.4))
            Text("아직 등록된 코스가 없어요")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.tteDarkGray)
            Spacer()
        }
    }

    // MARK: - Load

    private func loadAll() async {
        isLoading = true
        let blocked = userService.currentUser?.blockedUserIds ?? []
        let coord = locationService.currentLocation?.coordinate
        async let coursesTask: Void = courseService.fetchCourses(blockedUserIds: blocked)
        async let thumbsTask = CourseThumbnailService.shared.fetchAllThumbnails()
        async let recTask = RecommendationService.shared.fetchRecommended(
            userId: authService.currentUser?.uid,
            lat: coord?.latitude, lng: coord?.longitude
        )
        _ = await coursesTask
        thumbnails = await thumbsTask
        recommendedIds = await recTask
        isLoading = false
    }

    // 위치 확보 후 추천만 재조회 (전체 리로드 없이)
    private func refetchRecommendations() async {
        guard let coord = locationService.currentLocation?.coordinate else { return }
        let ids = await RecommendationService.shared.fetchRecommended(
            userId: authService.currentUser?.uid,
            lat: coord.latitude, lng: coord.longitude
        )
        await MainActor.run { recommendedIds = ids }
    }
}

// MARK: - Grid Cell

private struct GridCell: View {
    let course: Course
    let thumbnailURL: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(UIColor.secondarySystemBackground)

            if let url = thumbnailURL.flatMap(URL.init) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        DefaultCourseThumbnail(compact: true)
                    default:
                        Color(UIColor.secondarySystemBackground)
                    }
                }
            } else {
                DefaultCourseThumbnail(compact: true)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                Text(course.courseName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("\(course.region) · \(course.tag.rawValue)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(8)
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
    }
}
