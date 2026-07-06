import SwiftUI
import CoreLocation

struct ExploreGridView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService

    enum SortMode: String, CaseIterable {
        case recommended
        case latest
        case popular

        var displayName: String {
            switch self {
            case .recommended: return L("explore.sort.recommended")
            case .latest: return L("explore.sort.latest")
            case .popular: return L("explore.sort.popular")
            }
        }
    }

    @StateObject private var locationService = LocationService()
    @State private var sortMode: SortMode = .recommended
    @State private var thumbnails: [String: String] = [:]
    @State private var recommendedIds: [String] = []
    @State private var isLoading = false
    @State private var selectedCourse: Course?
    @State private var courseSessionInfo: CourseSessionInfo?
    @State private var pendingSessionInfo: CourseSessionInfo?
    @State private var didRefetchWithLocation = false
    @State private var creatorRanking: [CreatorRank] = []

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
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
                        if !creatorRanking.isEmpty {
                            creatorRankingStrip
                        }
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(sortedCourses) { course in
                                GridCell(course: course, thumbnailURL: thumbnails[course.courseId])
                                    .onTapGesture { selectedCourse = course }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    }
                }
            }
            .navigationTitle(L("tab.explore"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(item: $selectedCourse, onDismiss: {
            // 상세에서 "따라가기" 확정 시 → 닫힘 완료 후 세션 시작 (asyncAfter 타이밍 의존 제거)
            if let info = pendingSessionInfo {
                pendingSessionInfo = nil
                courseSessionInfo = info
            }
        }) { course in
            ExploreDetailView(course: course, thumbnailURL: thumbnails[course.courseId]) { roomIds in
                pendingSessionInfo = CourseSessionInfo(course: course, roomIds: roomIds)
                selectedCourse = nil
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
                        Text(mode.displayName)
                            .font(.tte(14, .semibold))
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

    // MARK: - 크리에이터 랭킹 스트립

    private var creatorRankingStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("explore.weeklyCreators"))
                .font(.tte(14, .bold))
                .foregroundColor(.tteDarkGray)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(creatorRanking) { creator in
                        VStack(spacing: 6) {
                            ZStack(alignment: .topLeading) {
                                Circle()
                                    .fill(Color.tteOrange.opacity(0.15))
                                    .frame(width: 56, height: 56)
                                    .overlay(
                                        Group {
                                            if let urlString = creator.profileImageUrl, let url = URL(string: urlString) {
                                                AsyncImage(url: url) { image in
                                                    image.resizable().scaledToFill()
                                                } placeholder: {
                                                    Text(String(creator.nickname.prefix(1)))
                                                        .font(.tte(20, .bold))
                                                        .foregroundColor(.tteOrange)
                                                }
                                            } else {
                                                Text(String(creator.nickname.prefix(1)))
                                                    .font(.tte(20, .bold))
                                                    .foregroundColor(.tteOrange)
                                            }
                                        }
                                        .frame(width: 56, height: 56)
                                        .clipShape(Circle())
                                    )
                                    .overlay(
                                        Circle().stroke(
                                            creator.rank == 1 ? Color.tteOrange : Color.clear,
                                            lineWidth: 2
                                        )
                                    )
                                Text("\(creator.rank)")
                                    .font(.tte(10, .heavy))
                                    .foregroundColor(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(creator.rank <= 3 ? Color.tteOrange : Color.tteMediumGray))
                                    .offset(x: -2, y: -2)
                            }
                            HStack(spacing: 2) {
                                Text(creator.nickname)
                                    .font(.tte(12, .semibold))
                                    .foregroundColor(.tteDarkGray)
                                    .lineLimit(1)
                                if creator.isVerified {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.tte(9))
                                        .foregroundColor(.tteOrange)
                                }
                            }
                            Text("♥ \(creator.likes)")
                                .font(.tte(10))
                                .foregroundColor(.tteMediumGray)
                        }
                        .frame(width: 72)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.tte(44))
                .foregroundColor(.tteOrange.opacity(0.4))
            Text(L("explore.empty"))
                .font(.tte(15, .semibold))
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
        async let rankTask = StatsService.shared.fetchCreatorRanking()
        _ = await coursesTask
        thumbnails = await thumbsTask
        recommendedIds = await recTask
        creatorRanking = await rankTask
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

    // 커스텀 썸네일이 없는 코스는 첫 장소(메인 장소) 사진을 대체 썸네일로 사용
    @State private var placePhotoURL: String?

    private var hasCustomThumbnail: Bool { thumbnailURL != nil }

    var body: some View {
        // Color로 열 너비에 맞는 3:4 세로 카드를 확정 → 이미지는 카드 크기에 맞춰 클립하고,
        // 그라디언트·텍스트는 "카드 하단"에 고정 (넘친 이미지 아래로 밀려 잘리지 않도록 레이어 분리)
        Color(UIColor.secondarySystemBackground)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                thumbnailImage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(course.courseName)
                            .font(.tte(14, .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        Text("\(course.region) · \(course.tag.displayName)")
                            .font(.tte(11))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    }
                    Spacer(minLength: 0)
                    // 좋아요 수 — 인기순 정렬의 근거가 카드에서 바로 보이도록
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill")
                            .font(.tte(10))
                        Text("\(course.likeCount)")
                            .font(.tte(11, .semibold))
                    }
                    .foregroundColor(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .task {
            // 커스텀 썸네일이 있으면 장소 사진을 굳이 조회하지 않음 (불필요한 API 호출 방지)
            guard !hasCustomThumbnail, placePhotoURL == nil,
                  let main = course.mainPlace else { return }
            placePhotoURL = await PlacesPhotoService.shared.photoURL(
                for: main.placeName, latitude: main.latitude, longitude: main.longitude)
        }
    }

    // 커스텀 썸네일 우선, 없으면 장소사진/기본 썸네일 폴백 — 정사각형을 꽉 채움
    @ViewBuilder
    private var thumbnailImage: some View {
        if let url = thumbnailURL.flatMap(URL.init) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeOrDefaultThumbnail
                default:
                    Color(UIColor.secondarySystemBackground)
                }
            }
        } else {
            placeOrDefaultThumbnail
        }
    }

    @ViewBuilder
    private var placeOrDefaultThumbnail: some View {
        if let url = placePhotoURL.flatMap(URL.init) {
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
    }
}
