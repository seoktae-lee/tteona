import SwiftUI
import Combine
import MapKit
import GoogleMaps

/// 지도에서 고른 코스를 담는 상자.
///
/// `@State`로 두면 마커 탭 클로저가 붙잡은 MainView 구조체의 State가 현재 화면의 저장소와
/// 끊겨 있을 때 값만 대입되고 화면은 그대로다 — 실제로 그랬다(설정 로그는 찍히는데
/// 카드가 만들어지지 않았다). 참조 타입이면 어느 시점에 붙잡힌 클로저든 같은 객체에 닿는다.
@MainActor
final class MapSelection: ObservableObject {
    @Published var course: Course?
    /// 검색해서 찍은 장소. 코스 카드와 같은 자리를 쓰고, 둘 중 하나라도 떠 있으면
    /// 컨테이너가 지도/탐색 토글을 접는다 — 그래서 지역 상태가 아니라 여기 둔다.
    @Published var place: PlaceSearchService.SearchResult?
}

struct MainView: View {
    /// DiscoverTabView의 지도/목록 토글이 차지하는 높이 — 상단 검색바를 그만큼 내린다
    var topInset: CGFloat = 0

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var notificationManager: AppNotificationManager
    @StateObject private var locationService = LocationService()
    @ObservedObject private var activeSessionStore = ActiveSessionStore.shared
    @ObservedObject private var tutorial = VlogTutorial.shared
    @State private var selectedCourse: Course?
    @State private var pendingSessionInfo: CourseSessionInfo? = nil
    @State private var pendingImpromptuRoomIds: Set<String>? = nil
    @State private var pendingReselectRooms = false
    @State private var impromptuRoomIds: Set<String>? = nil
    @State private var resumeActiveSession: Set<String>? = nil
    @State private var courseSessionInfo: CourseSessionInfo? = nil
    @State private var showCourseResumeSheet = false
    @State private var pendingCourseResume = false
    @State private var pendingNewCourse: Course? = nil
    @State private var showRoomSelect = false
    @State private var selectedRoomIds: Set<String> = []
    @State private var searchedRegionName: String? = nil
    @State private var showRegionSearch = false
    @State private var courseFilter: CourseFilter = .all
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var isLoadingCourses = false
    /// 이미 코스를 받아온 위도 밴드 — 지도를 움직일 때마다 같은 쿼리가 나가는 걸 막는다
    @State private var loadedBands: Set<String> = []
    /// 현재 지도 줌. 너무 멀리 보고 있으면 핀을 그리지 않으므로 그때 안내를 띄운다.
    @State private var mapZoom: Float = 6

    /// 지도 검색을 코스 이름에만 걸어두면 '양재고'처럼 **장소**를 찾는 사람은 빈손으로 나간다.
    /// 네이버·카카오 지도가 그러듯 입력하는 동안 장소 후보를 같이 보여주고,
    /// 고르면 그 자리로 이동해 핀을 세운다.
    @StateObject private var placeSearch = PlaceSearchService()
    /// 검색으로 찍은 장소 핀. 코스 핀과 별개로 지도에 하나만 떠 있는다.
    private var searchedPlace: PlaceSearchService.SearchResult? { selection.place }
    /// 코스 선택 상태를 **바깥에서 주입받는다.**
    /// 미리보기 카드가 떠 있는 동안 컨테이너(DiscoverTabView)의 지도/탐색 토글을
    /// 숨겨야 하는데, 그 토글은 이 뷰가 아니라 컨테이너 소유라서 상태를 공유해야 한다.
    @ObservedObject var selection: MapSelection

    enum CourseFilter { case all, liked, mine }
    // 구글맵 카메라 — cameraCommand에 값 세팅하면 그 위치로 이동(유저 팬 방해 없이)
    @State private var cameraCommand: GMSCameraPosition?
    @State private var didMoveToUser = false

    // MKCoordinateSpan(위도 델타) → 구글맵 zoom 레벨 변환
    private func gmsCamera(center: CLLocationCoordinate2D, latDelta: Double) -> GMSCameraPosition {
        let zoom = Float(max(3, min(19, log2(360.0 / max(latDelta, 0.0001)))))
        return GMSCameraPosition(latitude: center.latitude, longitude: center.longitude, zoom: zoom)
    }

    private var filteredCourses: [Course] {
        let base: [Course]
        switch courseFilter {
        case .all:   base = courseService.courses
        case .liked: base = courseService.courses.filter { courseService.likedCourseIds.contains($0.courseId) }
        case .mine:  base = courseService.courses.filter { $0.authorId == authService.currentUser?.uid }
        }

        let results: [Course]
        if courseNameQuery.isEmpty {
            results = base
        } else {
            let query = courseNameQuery.lowercased()
            results = base.filter {
                $0.courseName.lowercased().contains(query) ||
                $0.region.lowercased().contains(query) ||
                $0.places.contains(where: { $0.placeName.lowercased().contains(query) })
            }
        }

        return results.sorted { $0.likeCount > $1.likeCount }
    }

    /// 검색해서 찍은 장소 핀의 id — 코스 핀과 구분하려고 접두사를 붙인다
    private static let searchedPinId = "searched-place"

    // 지도에 찍을 마커 = 코스 핀 + (있으면) 검색한 장소 핀
    private var mapMarkers: [GoogleMapMarker] {
        var markers = courseMarkers
        if let place = searchedPlace {
            markers.append(GoogleMapMarker(
                id: Self.searchedPinId,
                coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                label: place.name,
                symbolName: "mappin"
            ))
        }
        return markers
    }

    /// 코스를 **이름으로** 거를 때 쓸 검색어.
    ///
    /// 검색창은 두 가지 뜻을 겸한다 — "이 이름의 코스를 걸러줘"와 "이 장소로 가줘".
    /// 장소를 골랐다면 뒤쪽이 확정된 것이므로 이름 필터는 손을 뗀다.
    /// (안 그러면 '판교백화점'을 찾아간 순간 그 자리에 있는 '판교 수다 코스'가
    ///  이름이 다르다는 이유로 걸러져, 코스가 하나도 없는 것처럼 보였다)
    private var courseNameQuery: String { selection.place == nil ? searchText : "" }

    // 지도에 찍을 코스 마커 (대표 장소 기준, 태그별 핀 + 코스명 라벨)
    private var courseMarkers: [GoogleMapMarker] {
        filteredCourses.compactMap { course in
            guard let main = course.mainPlace else { return nil }
            return GoogleMapMarker(
                id: course.courseId,
                coordinate: main.coordinate,
                pinImageName: course.tag.pinImageName,
                label: course.courseName,
                curated: course.isCurated
            )
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer

            // 이 오버레이는 '코스'가 없다는 뜻이다. 장소를 찾아 핀을 세웠거나 후보를
            // 고르는 중이라면 사용자는 막다른 길이 아니므로 띄우지 않는다.
            if !courseNameQuery.isEmpty && filteredCourses.isEmpty
                && searchedPlace == nil && placeSearch.results.isEmpty {
                emptySearchResultOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .zIndex(1)
            }

            if isLoadingCourses {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text(L("main.loadingCourses"))
                            .font(.tte(13))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(.bottom, 100)
                }
                .zIndex(2)
                .transition(.opacity)
            }

            // 핀을 그리지 않는 줌에서는 이유를 알려준다. 그냥 비어 있으면
            // "이 지역엔 코스가 없구나"로 읽혀 사용자가 확대해볼 생각을 하지 않는다.
            if mapZoom < GoogleMapView.Coordinator.pinMinZoom && !isLoadingCourses {
                VStack {
                    Spacer()
                    Text(L("main.zoomInForCourses"))
                        .font(.tte(13, .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        // 탭바(≈83) + 지도/탐색 토글(34+12)을 피해야 한다.
                        // 100으로 뒀더니 토글 뒤에 깔려 글자가 안 보였다.
                        .padding(.bottom, 170)
                }
                .zIndex(2)
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            topBar
            locationButton
            if selection.course == nil {
                createCourseButton
            }
            if let place = searchedPlace, selection.course == nil {
                searchedPlaceCard(place)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
                    .padding(.bottom, 83)
            }
            if let course = selection.course {
                CoursePreviewCard(course: course,
                                  distanceKm: distanceKm(to: course)) {
                    withAnimation(.spring(response: 0.3)) { selection.course = nil }
                    selectedCourse = course
                } onDismiss: {
                    withAnimation(.spring(response: 0.3)) { selection.course = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
                .padding(.bottom, 83)
            }
        }
        // ZStack 전체에 애니메이션을 걸면 그 안의 지도(UIViewRepresentable)까지 대상이 된다.
        // 갱신 그래프에 순환이 있는 상태에서는 이 트랜잭션이 통째로 버려져,
        // previewCourse를 바꿔도 카드가 아예 만들어지지 않았다.
        .ignoresSafeArea()
        .task {
            isLoadingCourses = true
            // 차단 목록이 아직 로드 전이면 먼저 로드 — 차단 필터 누락 방지
            if userService.currentUser == nil, let uid = authService.currentUser?.uid {
                await userService.fetchUser(uid: uid)
            }
            await courseService.fetchCourses(blockedUserIds: userService.currentUser?.blockedUserIds ?? [])
            if let uid = authService.currentUser?.uid {
                await courseService.fetchLikedCourseIds(userId: uid)
            }
            isLoadingCourses = false
            locationService.requestPermission()
            locationService.startTracking(places: [])
            if let coord = locationService.currentLocation?.coordinate {
                await moveToUserArea(coord: coord)
            }
        }
        .onChange(of: locationService.currentLocation) { _, location in
            guard !didMoveToUser, let coord = location?.coordinate else { return }
            Task { await moveToUserArea(coord: coord) }
        }
        .sheet(item: $selectedCourse, onDismiss: {
            // 상세에서 "떠나기" 확정 시 → 시트 닫힘 완료 후 세션 시작 (asyncAfter 타이밍 의존 제거)
            if let info = pendingSessionInfo {
                pendingSessionInfo = nil
                courseSessionInfo = info
            }
        }) { course in
            CourseDetailView(course: course) { roomIds in
                pendingSessionInfo = CourseSessionInfo(course: course, roomIds: roomIds)
                selectedCourse = nil
            }
            .environmentObject(authService)
            .environmentObject(courseService)
            .environmentObject(userService)
            .environmentObject(roomService)
        }
        .sheet(isPresented: $showRegionSearch) {
            RegionSearchView { name, coord in
                searchedRegionName = name
                cameraCommand = gmsCamera(center: coord, latDelta: 0.05)
                // 선택한 지역의 코스도 별도로 불러와 병합
                Task { await courseService.fetchCoursesInRegion(name, blockedUserIds: userService.currentUser?.blockedUserIds ?? []) }
            }
        }
        .sheet(isPresented: $showCourseResumeSheet, onDismiss: {
            guard pendingCourseResume else { return }
            pendingCourseResume = false
            if let session = ActiveSessionStore.shared.loadTodaySession() {
                courseSessionInfo = CourseSessionInfo(
                    course: session.course.toCourse(),
                    roomIds: Set(session.roomIds),
                    isResuming: true
                )
            }
        }) {
            courseResumeSheet()
        }
        .fullScreenCover(isPresented: $showRoomSelect, onDismiss: {
            // 방 선택 확정 시 → 닫힘 완료 후 '나의 오늘' 세션 시작
            if let confirmed = pendingImpromptuRoomIds {
                pendingImpromptuRoomIds = nil
                impromptuRoomIds = confirmed
            }
        }) {
            RoomSelectView(selectedRoomIds: $selectedRoomIds) {
                pendingImpromptuRoomIds = selectedRoomIds
                showRoomSelect = false
            }
            .environmentObject(roomService)
        }
        .fullScreenCover(item: $impromptuRoomIds, onDismiss: {
            // 세션에서 "방 다시 선택" 요청 시 → 닫힘 완료 후 방 선택 화면 재오픈
            if pendingReselectRooms {
                pendingReselectRooms = false
                showRoomSelect = true
            }
        }) { roomIds in
            ImpromptuSessionView(selectedRoomIds: roomIds) {
                pendingReselectRooms = true
                impromptuRoomIds = nil
            }
            .environmentObject(authService)
            .environmentObject(userService)
            .environmentObject(courseService)
            .environmentObject(roomService)
        }
        .fullScreenCover(item: $courseSessionInfo) { info in
            ActiveSessionView(course: info.course, roomIds: info.roomIds, isResuming: info.isResuming)
                .environmentObject(AppNotificationManager.shared)
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .onChange(of: notificationManager.shouldOpenTodaySession) { _, should in
            guard should else { return }
            notificationManager.shouldOpenTodaySession = false
            handleImpromptuTap()
        }
        .onAppear {
            // 콜드 스타트: 잠금화면 촬영 버튼/알림이 MainView 등장 전에 신호를 세팅한 경우
            if notificationManager.shouldOpenTodaySession {
                notificationManager.shouldOpenTodaySession = false
                handleImpromptuTap()
            }
        }
    }

    /// 내 위치에서 코스 대표 장소까지의 거리(km).
    /// 부산 코스를 서울에서 보는 사람에게는 이게 가장 먼저 필요한 정보다.
    /// 위치 권한이 없으면 nil — 그 줄만 빠진다.
    private func distanceKm(to course: Course) -> Double? {
        guard let me = locationService.currentLocation,
              let main = course.mainPlace else { return nil }
        let target = CLLocation(latitude: main.latitude, longitude: main.longitude)
        return me.distance(from: target) / 1000
    }

    // MARK: - Map
    private var mapLayer: some View {
        GoogleMapView(
            markers: mapMarkers,
            showsUserLocation: true,
            initialCamera: gmsCamera(center: CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8), latDelta: 5),
            thinsMarkers: true,
            cameraCommand: $cameraCommand,
            onMarkerTap: { courseId in
                // 검색 핀은 코스가 아니다 — 코스 조회로 넘기면 조용히 무시될 뿐이라 명시한다
                guard courseId != Self.searchedPinId else { return }
                guard let course = filteredCourses.first(where: { $0.courseId == courseId }) else { return }
                Task { await StatsService.shared.postCourseEvent(.pinTap, course: course) }
                if activeSessionStore.hasTodaySession {
                    pendingNewCourse = course
                    showCourseResumeSheet = true
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selection.course = course
                    }
                }
            },
            onCameraIdle: { position in
                if mapZoom != position.zoom { mapZoom = position.zoom }
                loadCoursesForVisibleArea(position)
            }
        )
    }

    /// 지도를 옮긴 자리의 코스를 채운다.
    ///
    /// 기본 로드는 인기 상위 300 + 큐레이션 상한이라, 전국 코스가 늘어나면 화면을 옮겨도
    /// 그 동네 코스가 없는 상태가 된다. 카메라가 멈출 때 그 지역만 추가로 받아 메운다.
    ///
    /// 같은 밴드를 반복해서 받지 않도록 **이미 받아온 밴드를 기억**한다. 이게 없으면
    /// 지도를 조금 움직일 때마다 같은 쿼리가 나가 읽기 비용이 걷잡을 수 없이 늘어난다.
    /// 줌이 너무 멀면(전국 조망) 밴드 하나로 담을 수 없어 건너뛴다.
    private func loadCoursesForVisibleArea(_ position: GMSCameraPosition) {
        guard position.zoom >= 8 else { return }
        let band = Course.latBand(for: position.target.latitude)
        guard !loadedBands.contains(band) else { return }
        loadedBands.insert(band)
        Task {
            await courseService.fetchCoursesNear(
                latitude: position.target.latitude, longitude: position.target.longitude,
                blockedUserIds: userService.currentUser?.blockedUserIds ?? []
            )
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack {
            GeometryReader { geo in
                let spacing: CGFloat = 12
                let buttonSize: CGFloat = 40

                HStack(spacing: 12) {
                    // 검색 바
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.tte(14, .medium))
                            .foregroundColor(.tteMediumGray)
                        
                        TextField(L("main.searchPlaceholder"), text: $searchText)
                            .font(.tte(14))
                            .foregroundColor(.tteDarkGray)
                            .autocorrectionDisabled()
                            .focused($searchFocused)
                            .onSubmit {
                                searchFocused = false
                                Task { await performMapSearch() }
                            }
                            .onChange(of: searchText) { _, text in
                                // 한국 밖에서는 MapKit으로 넘어가야 해서 기준 좌표를 먼저 맞춘다
                                if let me = locationService.currentLocation?.coordinate {
                                    placeSearch.searchCoordinate = me
                                }
                                let q = text.trimmingCharacters(in: .whitespaces)
                                if q.isEmpty { placeSearch.results = [] }
                                else { placeSearch.searchDebounced(q) }
                            }
                        
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                                placeSearch.results = []
                                selection.place = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.tteMediumGray)
                            }
                            .accessibilityLabel(L("main.clearSearch"))
                        }

                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 4)

                        Button {
                            showRegionSearch = true
                        } label: {
                            Image(systemName: "map.fill")
                                .font(.tte(14))
                                .foregroundColor(.tteOrange)
                        }
                        .accessibilityLabel(L("region.title"))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: buttonSize)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)

                    // 코스 필터
                    HStack(spacing: 0) {
                        ForEach([
                            ("square.grid.2x2.fill", CourseFilter.all,   L("main.filter.all")),
                            ("heart.fill",            .liked, L("main.filter.liked")),
                            ("person.fill",           .mine,  L("main.filter.mine"))
                        ], id: \.0) { icon, filter, label in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { courseFilter = filter }
                            } label: {
                                Image(systemName: icon)
                                    .font(.tte(14))
                                    .foregroundColor(courseFilter == filter ? .white : .tteOrange)
                                    .frame(width: buttonSize, height: buttonSize)
                                    .background(Circle().fill(courseFilter == filter ? Color.tteOrange : Color.clear))
                            }
                            .accessibilityLabel(label)
                        }
                    }
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 40)
            .padding(.top, topSafeInset + 8 + topInset)

            // 검색 제안 카드 — "타이핑=코스 필터 / 지도 이동=명시적 선택"으로 이중 역할 분리
            if searchFocused && !searchText.isEmpty {
                searchSuggestionCard
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: searchFocused && !searchText.isEmpty)
    }

    /// 기기별 상단 세이프에어리어 — 컨테이너가 ignoresSafeArea 상태라 윈도우에서 직접 조회
    /// (기존 고정 56pt는 노치/다이나믹아일랜드/SE에서 어긋남)
    private var topSafeInset: CGFloat {
        let inset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
        return max(inset, 20)
    }

    // MARK: - 검색 제안 카드
    //
    // 입력은 두 가지 뜻을 가진다 — "이 이름의 코스를 걸러줘"와 "이 장소로 가줘".
    // 예전엔 뒤쪽이 '지도에서 찾기' 한 줄에 숨어 있어서 '양재고'를 친 사람은
    // 코스 0개만 보고 막다른 길에 섰다. 이제 장소 후보를 직접 늘어놓는다.
    private var searchSuggestionCard: some View {
        VStack(spacing: 0) {
            if !placeSearch.results.isEmpty {
                sectionHeader(L("main.searchSectionPlaces"))
                ForEach(placeSearch.results.prefix(5)) { place in
                    Button { selectPlace(place) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.tte(15))
                                .foregroundColor(.tteOrange)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name)
                                    .font(.tte(14, .medium))
                                    .foregroundColor(.tteDarkGray)
                                    .lineLimit(1)
                                if !place.address.isEmpty {
                                    Text(place.address)
                                        .font(.tte(11))
                                        .foregroundColor(.tteMediumGray)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.tte(12))
                                .foregroundColor(.tteMediumGray)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                    }
                }
                Divider().padding(.leading, 46)
            } else if placeSearch.isSearching {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.7).frame(width: 22)
                    Text(L("main.searchSectionPlaces"))
                        .font(.tte(13))
                        .foregroundColor(.tteMediumGray)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                Divider().padding(.leading, 46)
            } else {
                // 카카오·MapKit이 아무것도 못 찾은 경우에도 길은 남겨둔다 —
                // 지역명처럼 '장소'가 아닌 입력은 여기로 흡수된다.
                Button {
                    searchFocused = false
                    Task { await performMapSearch() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "location.magnifyingglass")
                            .font(.tte(14))
                            .foregroundColor(.tteOrange)
                            .frame(width: 22)
                        Text(L("main.goToRegion", searchText.trimmingCharacters(in: .whitespaces)))
                            .font(.tte(14, .medium))
                            .foregroundColor(.tteDarkGray)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.tte(12))
                            .foregroundColor(.tteMediumGray)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                Divider().padding(.leading, 46)
            }

            // 현재 입력으로 필터된 코스 수 — 탭하면 키보드를 내리고 지도에서 확인
            Button {
                searchFocused = false
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.tte(14))
                        .foregroundColor(.tteOrange)
                        .frame(width: 22)
                    Text(L("main.courseResults", filteredCourses.count))
                        .font(.tte(14, .medium))
                        .foregroundColor(.tteDarkGray)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.tteBackground)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        )
    }

    /// 검색해서 찾아간 장소를 지도 위에서 한 번 더 확인시켜 준다.
    /// 핀만 세우면 "여기가 맞나?"에서 끝나는데, 사람이 장소를 찾아온 진짜 이유는
    /// 대개 "여기 뭐 있지?"라서 근처 코스 수를 같이 보여준다.
    private func searchedPlaceCard(_ place: PlaceSearchService.SearchResult) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.tte(22))
                .foregroundColor(.tteOrange)

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.tte(16, .bold))
                    .foregroundColor(.tteDarkGray)
                    .lineLimit(1)
                if !place.address.isEmpty {
                    Text(place.address)
                        .font(.tte(11.5))
                        .foregroundColor(.tteMediumGray)
                        .lineLimit(1)
                }
                let count = nearbyCourseCount(of: place)
                Text(count > 0 ? L("main.nearbyCourses", count) : L("main.nearbyCoursesNone"))
                    .font(.tte(12, .medium))
                    .foregroundColor(count > 0 ? .tteOrange : .tteMediumGray)
                    .padding(.top, 1)
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.spring(response: 0.3)) { selection.place = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.tte(12, .semibold))
                    .foregroundColor(.tteMediumGray)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color(UIColor.secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("main.clearSearchedPlace"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.tteBackground)
                .shadow(color: .black.opacity(0.12), radius: 14, y: -3)
        )
        .padding(.horizontal, 12)
    }

    /// 지도에 이미 올라와 있는 코스 중 그 장소 5km 안에 있는 것
    private func nearbyCourseCount(of place: PlaceSearchService.SearchResult) -> Int {
        let origin = CLLocation(latitude: place.latitude, longitude: place.longitude)
        return filteredCourses.filter { course in
            guard let main = course.mainPlace else { return false }
            return origin.distance(from: CLLocation(latitude: main.latitude,
                                                    longitude: main.longitude)) <= 5000
        }.count
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.tte(11, .semibold))
                .foregroundColor(.tteMediumGray)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// 고른 장소로 지도를 옮기고 핀을 세운다.
    /// 그 동네 코스도 함께 불러온다 — 장소를 찾아온 사람이 진짜 원하는 건 대개 "여기 뭐 있지?"다.
    private func selectPlace(_ place: PlaceSearchService.SearchResult) {
        Haptics.light()
        searchFocused = false
        withAnimation(.spring(response: 0.3)) { selection.place = place }
        withAnimation(.spring(response: 0.3)) { selection.course = nil }
        cameraCommand = gmsCamera(
            center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
            latDelta: 0.02
        )
        Task {
            await courseService.fetchCoursesNear(
                latitude: place.latitude, longitude: place.longitude,
                blockedUserIds: userService.currentUser?.blockedUserIds ?? []
            )
        }
    }

    // MARK: - 나라 크기에 맞는 줌 레벨로 이동
    /// 위치를 잡으면 **내 주변**으로 이동한다.
    ///
    /// 예전에는 나라 전체가 보이는 줌으로 맞췄다(moveToCountry). 코스가 수십 개일 땐
    /// "우리 앱이 전국을 다룬다"는 인상을 줬지만, 900개가 넘자 전국 화면이 커다란
    /// 클러스터 숫자로 뒤덮여 아무 쓸모가 없어졌다 — 전국에 157개가 있다는 정보는
    /// 사용자의 다음 행동으로 이어지지 않는다.
    ///
    /// 지도 앱들이 그러하듯(네이버·카카오는 전국에서 핀을 아예 안 띄우고, 에어비앤비는
    /// 화면에 20개 남짓만 보여준다) **처음부터 갈 만한 거리**를 보여준다.
    private func moveToUserArea(coord: CLLocationCoordinate2D) async {
        await MainActor.run {
            didMoveToUser = true
            cameraCommand = gmsCamera(center: coord, latDelta: Self.userAreaSpan)
        }
    }

    /// 내 위치로 맞출 때의 위도 폭(도). 0.125° ≈ 14km — 시 하나가 화면에 담긴다.
    /// 실측으로 고른 값이다: 이 줌에서 화면에 뜨는 마커가 서울 20개·부산 8개·강릉 6개로
    /// 대부분 개별 핀이고, 클러스터는 몇 개만 섞인다.
    private static let userAreaSpan: Double = 0.125

    private func handleImpromptuTap() {
        selectedRoomIds = []
        courseSessionInfo = nil  // courseSessionInfo가 남아있으면 fullScreenCover 충돌 방지
        let saved = ImpromptuSessionStore.shared.loadTodaySession()
        let hasSavedSession = saved.map { !$0.places.isEmpty } ?? false
        if hasSavedSession || roomService.myRooms.isEmpty {
            impromptuRoomIds = Set(saved?.roomIds ?? [])
        } else {
            showRoomSelect = true
        }
    }

    // MARK: - Course Resume Sheet
    @ViewBuilder
    private func courseResumeSheet() -> some View {
        let saved = ActiveSessionStore.shared.loadTodaySession()
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 24)

            ZStack {
                Circle()
                    .fill(Color.tteOrange.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.tte(30))
                    .foregroundColor(.tteOrange)
            }
            .padding(.bottom, 16)

            VStack(spacing: 6) {
                Text(L("main.activeCourseBanner"))
                    .font(.tte(20, .bold))
                    .foregroundColor(.tteDarkGray)
                if let saved {
                    Text(L("main.courseProgress", saved.course.courseName, saved.visitedPlaceOrders.count, saved.orderedPlaces.count))
                        .font(.tte(14))
                        .foregroundColor(.tteMediumGray)
                }
            }
            .padding(.bottom, 32)

            VStack(spacing: 12) {
                // 이어서 기록하기
                Button {
                    pendingNewCourse = nil
                    pendingCourseResume = true
                    showCourseResumeSheet = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill").font(.tte(15))
                        Text(L("main.continueRecording")).font(.tte(16, .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }

                // 새로 시작하기 — 기존 세션 삭제 후, 방금 탭한 코스가 있으면 그 프리뷰로 이어간다.
                // (예전엔 pendingNewCourse를 그냥 버려서 핀을 탭하고 새로시작하면 아무 일도 안 났다.)
                Button {
                    showCourseResumeSheet = false
                    ActiveSessionStore.shared.clear()
                    let tapped = pendingNewCourse
                    pendingNewCourse = nil
                    if let tapped {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selection.course = tapped
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise").font(.tte(15))
                        Text(L("main.startFresh"))
                            .font(.tte(16, .medium))
                    }
                    .foregroundColor(.tteDarkGray)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemBackground)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
    }

    // MARK: - Bottom Buttons
    private var locationButton: some View { EmptyView() }

    private var createCourseButton: some View {
        VStack {
            Spacer()

            ZStack(alignment: .bottom) {
                // 보조 버튼 — 좌: 이어하기 도크(세로 스택 → 중앙 CTA와 겹침 방지), 우: 현재 위치
                HStack(alignment: .bottom) {
                    VStack(spacing: 10) {
                        // '나의 오늘 이어하기'는 촬영 탭이 가져갔다 — 세션의 주인이 둘이면
                        // 상태가 어긋나 한쪽 버튼이 안 사라지는 문제가 생긴다.
                        // 진행 중인 세션은 촬영 탭 상단 칩에서 확인·마무리한다.

                        // 코스 이어하기
                        if activeSessionStore.hasTodaySession {
                            miniDockButton(icon: "map.fill", label: L("main.course")) {
                                pendingNewCourse = nil
                                showCourseResumeSheet = true
                            }
                        }
                    }
                    .padding(.leading, 24)

                    Spacer()

                    // 현재 위치
                    miniDockButton(icon: "location.fill", label: nil) {
                        guard let coord = locationService.currentLocation?.coordinate else { return }
                        cameraCommand = gmsCamera(center: coord, latDelta: 0.05)
                    }
                    .accessibilityLabel(L("main.moveToCurrentLocation"))
                    .padding(.trailing, 24)
                }

                // '나의 오늘' CTA는 촬영 탭으로 옮겨졌다 — 이 자리는 지도/탐색 토글이 쓴다
                // (토글 자체는 DiscoverTabView가 그린다)
            }
            .padding(.bottom, 104)
        }
    }

    /// 지도 위 48pt 원형 보조 버튼 — 이어하기·현재위치 공용 (스타일 일원화)
    private func miniDockButton(icon: String, label: String?, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.tte(label == nil ? 18 : 16, .semibold))
                if let label {
                    Text(label)
                        .font(.tte(9, .medium))
                }
            }
            .foregroundColor(.tteOrange)
            .frame(width: 48, height: 48)
            .background(Circle().fill(Color.tteBackground).shadow(color: .black.opacity(0.15), radius: 8, y: 2))
        }
    }

}

extension Notification.Name {
    static let activeSessionDidChange = Notification.Name("activeSessionDidChange")
}

// MARK: - Map Pin
struct CourseMapPin: View {
    let course: Course

    private var pinImageName: String {
        switch course.tag {
        case .couple:  return "pin_couple"
        case .family:  return "pin_family"
        case .solo:    return "pin_solo"
        case .friends: return "pin_friends"
        }
    }

    var body: some View {
        Image(pinImageName)
            .resizable()
            .scaledToFit()
            .frame(width: 46, height: 46)
            .shadow(color: .tteOrange.opacity(0.4), radius: 4)
    }
}


// MARK: - Course Card (나의 코스 탭용으로 유지)
struct CourseCardView: View {
    let course: Course
    @State private var photoURL: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 배경 사진
            if let urlStr = photoURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.tteOrange.opacity(0.08)
                    }
                }
            } else {
                Color.tteOrange.opacity(0.08)
            }

            // 그라디언트 오버레이 (텍스트 가독성)
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )

            // 텍스트 콘텐츠
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(course.tag.displayName)
                        .font(.tte(11, .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.tteOrange))
                    Text(course.region)
                        .font(.tte(11))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                }
                Text(course.courseName)
                    .font(.tte(15, .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.tte(12))
                        Text(L("main.placesCount", course.places.count))
                            .font(.tte(12))
                    }
                    .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill")
                            .font(.tte(12))
                        Text("\(course.likeCount)")
                            .font(.tte(12))
                    }
                    .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(14)
        }
        .frame(width: 220, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .task {
            if let main = course.mainPlace {
                photoURL = await PlacesPhotoService.shared.photoURL(
                    for: main.placeName, latitude: main.latitude, longitude: main.longitude)
            }
        }
    }
}

extension MainView {
    // MARK: - Empty Search Result
    private var emptySearchResultOverlay: some View {
        TteEmptyState(
            image: "tteoni-wink",
            title: L("main.noSearchResults"),
            subtitle: L("main.tryOtherKeyword"),
            imageSize: 100
        )
        .padding(.vertical, 36)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.1), radius: 20)
        .padding(.bottom, 100)
    }

    // MARK: - Map Search & Move
    private func performMapSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }

        // 카카오 우선(한국 지명 정확) → 없으면 MapKit 폴백 (PlaceSearchService 내부 처리)
        // 이름으로 지은 region("서울"·"제주")을 쓰던 초기 코스를 위해 텍스트 조회도 남겨둔다
        await courseService.fetchCoursesInRegion(q, blockedUserIds: userService.currentUser?.blockedUserIds ?? [])

        let svc = PlaceSearchService()
        await svc.search(q)
        if let first = svc.results.first {
            selection.place = first
            cameraCommand = gmsCamera(
                center: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                latDelta: 0.1
            )
            // 지금 코스는 region이 위도 밴드라 좌표로 찾아야 주변 코스가 딸려온다
            await courseService.fetchCoursesNear(
                latitude: first.latitude, longitude: first.longitude,
                blockedUserIds: userService.currentUser?.blockedUserIds ?? []
            )
        }
    }
}

extension Set: @retroactive Identifiable where Element == String {
    public var id: String { sorted().joined(separator: ",") }
}

extension MKCoordinateRegion {
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let latOK = abs(coordinate.latitude - center.latitude) <= span.latitudeDelta / 2
        let lonOK = abs(coordinate.longitude - center.longitude) <= span.longitudeDelta / 2
        return latOK && lonOK
    }
}

// MARK: - 지도 핀 탭 미니카드
struct CoursePreviewCard: View {
    let course: Course
    /// 내 위치에서의 거리(km). 위치를 모르면 nil이고 그 항목만 빠진다.
    var distanceKm: Double? = nil
    let onTap: () -> Void
    let onDismiss: () -> Void
    @State private var isAuthorVerified = false
    @State private var authorNickname: String = ""
    @EnvironmentObject private var userService: UserService

    // 정보 순서만 뒤집었다. 카드는 **작게** 유지한다.
    //
    // 예전엔 썸네일이 먼저 나오고 판단에 필요한 제목·규모·인기가 그 아래 눌려 있었다.
    // 핀을 누른 사람의 질문은 "이거 갈까?"라서 그 답부터 위에 놓고 썸네일을 보조로 내렸다.
    // 대신 전체 폭 CTA 같은 걸 넣어 카드를 키우지 않는다 — 지도를 가리면 핀을 여러 개
    // 눌러 비교하는 이 화면의 쓸모가 사라지고, 실제로 탭바 뒤로 깔리기도 했다.
    // 상세로 가는 길은 카드 전체 탭 + 오른쪽 셰브론 하나로 충분하다.
    var body: some View {
        VStack(spacing: 0) {
            handle

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(course.courseName)
                            .font(.tte(17, .bold))
                            .foregroundColor(.tteDarkGray)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if isAuthorVerified { VerifiedBadge(creatorLabel: nil) }
                        if !authorNickname.isEmpty {
                            Text(authorNickname)
                                .font(.tte(12))
                                .foregroundColor(.tteMediumGray)
                                .lineLimit(1)
                        }
                    }
                    metaRow
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.tte(15, .semibold))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 연속 중복 장소는 하나로 병합해 표시 (저장 데이터는 원본 유지)
                    ForEach(course.displayPlaces) { place in
                        PlacePhotoThumbnail(place: place)
                    }
                }
                .padding(.horizontal, 18)
            }
            .frame(height: 130)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.tteBackground)
                .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task {
            let author = await userService.fetchAuthor(uid: course.authorId)
            isAuthorVerified = author?.isVerified ?? false
            authorNickname = author?.nickname ?? ""
        }
    }

    private var handle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color(UIColor.tertiaryLabel))
                .frame(width: 36, height: 5)
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.tte(12, .semibold))
                        .foregroundColor(.tteMediumGray)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(UIColor.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("main.closePreview"))
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    /// 판단에 필요한 것만 한 줄로 — 태그 · 거리 · 장소 수 · 좋아요
    private var metaRow: some View {
        HStack(spacing: 8) {
            Text(course.tag.displayName)
                .font(.tte(11, .semibold))
                .foregroundColor(.tteOrange)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.tteOrange.opacity(0.12)))

            if let km = distanceKm {
                Label(km < 1 ? L("main.distanceNear")
                             : L("main.distanceKm", Int(km.rounded())),
                      systemImage: "location.fill")
                    .font(.tte(12))
                    .labelStyle(.titleAndIcon)
                    .foregroundColor(.tteMediumGray)
            }

            Text(L("main.placeCount", course.displayPlaces.count))
                .font(.tte(12))
                .foregroundColor(.tteMediumGray)

            HStack(spacing: 3) {
                Image(systemName: "heart.fill").font(.tte(11))
                Text("\(course.likeCount)").font(.tte(12))
            }
            .foregroundColor(.tteMediumGray)
        }
        .lineLimit(1)
    }
}

struct PlacePhotoThumbnail: View {
    let place: Place
    @State private var photoURL: String?
    @State private var category: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if isLoading {
                        thumbnailLoadingPlaceholder
                    } else if let urlStr = photoURL, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            case .failure:
                                thumbnailFailurePlaceholder
                            default:
                                thumbnailLoadingPlaceholder
                            }
                        }
                    } else {
                        thumbnailFailurePlaceholder
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("\(place.order)")
                    .font(.tte(10, .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.tteOrange))
                    .offset(x: 4, y: -4)
            }

            Text(place.placeName)
                .font(.tte(11, .medium))
                .foregroundColor(.tteDarkGray)
                .lineLimit(1)
                .frame(width: 80)

            if let category {
                Text(category)
                    .font(.tte(10))
                    .foregroundColor(.tteMediumGray)
                    .lineLimit(1)
                    .frame(width: 80)
            } else {
                Spacer().frame(height: 13)
            }
        }
        .task {
            async let photo = PlacesPhotoService.shared.photoURL(
                for: place.placeName, latitude: place.latitude, longitude: place.longitude)
            async let cat = PlacesPhotoService.shared.placeCategory(
                for: place.placeName, latitude: place.latitude, longitude: place.longitude)
            (photoURL, category) = await (photo, cat)
            isLoading = false
        }
    }

    private var thumbnailLoadingPlaceholder: some View {
        ZStack {
            Color.tteOrange.opacity(0.06)
            Image("tteona-icon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(12)
            ProgressView()
                .tint(Color.white)
                .scaleEffect(0.8)
                .offset(y: -4)
        }
    }

    private var thumbnailFailurePlaceholder: some View {
        ZStack {
            Color.tteOrange.opacity(0.06)
            Image("tteona-no-image")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(6)
        }
    }
}

#Preview {
    MainView(selection: MapSelection())
        .environmentObject(AuthService())
        .environmentObject(CourseService())
}
