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
    // 탭한 코스가 상세로 열릴 때까지 해당 카드에만 로딩 인디케이터
    @State private var openingCourseId: String? = nil
    // 코스 제목(UGC) 번역문 — 원문 → 번역문. 없으면 카드가 원문을 그대로 쓴다.
    @State private var translatedTitles: [String: String] = [:]

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    /// 유저 선호 태그 (온보딩/설정에서 선택) — 추천 API와 로컬 폴백 정렬에 반영
    private var preferredCourseTag: CourseTag? {
        userService.currentUser?.preferredTag.flatMap(CourseTag.init(rawValue:))
    }

    private var sortedCourses: [Course] {
        let base = courseService.courses
        switch sortMode {
        case .latest:
            return base.sorted { $0.createdAt > $1.createdAt }
        case .popular:
            return base.sorted { $0.likeCount > $1.likeCount }
        case .recommended:
            guard !recommendedIds.isEmpty else {
                // 서버 추천 도착 전 폴백: 선호 태그 코스 우선 → 인기순
                let pref = preferredCourseTag
                return base.sorted {
                    if let pref, ($0.tag == pref) != ($1.tag == pref) { return $0.tag == pref }
                    return $0.likeCount > $1.likeCount
                }
            }
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
                    skeletonGrid
                } else if sortedCourses.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        if !creatorRanking.isEmpty {
                            creatorRankingStrip
                        }
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(sortedCourses) { course in
                                GridCell(course: course, thumbnailURL: thumbnails[course.courseId],
                                         translatedTitle: translatedTitles[course.courseName],
                                         isOpening: openingCourseId == course.courseId) {
                                    Haptics.light()
                                    openingCourseId = course.courseId
                                    selectedCourse = course
                                }
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
            openingCourseId = nil
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
            .onAppear { openingCourseId = nil }
        }
        .task {
            locationService.requestPermission()
            locationService.startTracking(places: [])
            await loadAll()
        }
        // 당김 제스처가 끝나면 SwiftUI가 refreshable 태스크를 취소해 조회들이 중도 실패한다.
        // 비구조화 Task로 감싸 취소 전파를 끊고 끝까지 완주시킨다.
        .refreshable { await Task { await loadAll() }.value }
        .onChange(of: locationService.currentLocation) { _, loc in
            // 위치를 처음 확보하면 위치 기반으로 추천 1회 재조회
            guard !didRefetchWithLocation, loc != nil else { return }
            didRefetchWithLocation = true
            Task { await refetchRecommendations() }
        }
        .onChange(of: userService.currentUser?.preferredTag) { _, _ in
            // 설정에서 여행 취향 변경 시 추천 즉시 갱신
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
        VStack {
            Spacer()
            TteEmptyState(image: "tteoni-guide", title: L("explore.empty"))
            Spacer()
        }
    }

    // MARK: - 스켈레톤 로딩 (spinner 대신 카드 자리 표시 → 체감 로딩 개선)

    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonGridCell()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .disabled(true)
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
            lat: coord?.latitude, lng: coord?.longitude,
            tag: preferredCourseTag
        )
        async let rankTask = StatsService.shared.fetchCreatorRanking()
        _ = await coursesTask
        let thumbs = await thumbsTask
        if !thumbs.isEmpty { thumbnails = thumbs }
        recommendedIds = await recTask
        // 랭킹 조회가 실패하면(nil) 기존 스트립을 그대로 둔다 — 당겨서 새로고침 중
        // 태스크가 취소되면 빈 배열이 내려와 섹션이 사라지는 문제가 있었다.
        if let ranking = await rankTask { creatorRanking = ranking }
        isLoading = false

        // 제목 번역은 기다리지 않는다 — loadAll을 await하는 .refreshable의 당김 스피너가
        // 번역 왕복만큼 더 돌게 된다. 원문으로 먼저 그리고, 번역문이 오면 교체한다.
        let titles = courseService.courses.map(\.courseName)
        Task {
            let translated = await TranslationService.shared.translate(
                titles, to: LanguageManager.shared.language)
            if !translated.isEmpty { translatedTitles = translated }
        }
    }

    // 위치 확보·취향 변경 후 추천만 재조회 (전체 리로드 없이)
    private func refetchRecommendations() async {
        let coord = locationService.currentLocation?.coordinate
        let ids = await RecommendationService.shared.fetchRecommended(
            userId: authService.currentUser?.uid,
            lat: coord?.latitude, lng: coord?.longitude,
            tag: preferredCourseTag
        )
        await MainActor.run { recommendedIds = ids }
    }
}

// MARK: - Skeleton Cell

private struct SkeletonGridCell: View {
    @State private var pulse = false

    var body: some View {
        Color(UIColor.secondarySystemBackground)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(Color(UIColor.tertiarySystemFill))
                        .frame(width: 110, height: 12)
                    Capsule()
                        .fill(Color(UIColor.tertiarySystemFill))
                        .frame(width: 70, height: 9)
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(pulse ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - Grid Cell

private struct GridCell: View {
    let course: Course
    let thumbnailURL: String?
    var translatedTitle: String? = nil
    var isOpening: Bool = false
    var onTap: () -> Void = {}

    // 커스텀 썸네일이 없는 코스는 첫 장소(메인 장소) 사진을 대체 썸네일로 사용
    @State private var placePhotoURL: String?

    private var hasCustomThumbnail: Bool { thumbnailURL != nil }

    var body: some View {
        Button(action: onTap) { cardBody }
            .buttonStyle(PressableCardStyle())
            .task {
                // 커스텀 썸네일이 있으면 장소 사진을 굳이 조회하지 않음 (불필요한 API 호출 방지)
                guard !hasCustomThumbnail, placePhotoURL == nil,
                      let main = course.mainPlace else { return }
                placePhotoURL = await PlacesPhotoService.shared.photoURL(
                    for: main.placeName, latitude: main.latitude, longitude: main.longitude)
            }
    }

    private var cardBody: some View {
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
                        Text(translatedTitle ?? course.courseName)
                            .font(.tte(14, .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        Text("\(course.localizedRegion) · \(course.tag.displayName)")
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
            // 상세가 뜰 때까지 이 카드에만 로딩 인디케이터
            .overlay {
                if isOpening {
                    ZStack {
                        Color.black.opacity(0.35)
                        ProgressView().tint(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isOpening)
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
