import SwiftUI
import MapKit
import GoogleMaps

struct MainView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var notificationManager: AppNotificationManager
    @StateObject private var locationService = LocationService()
    @ObservedObject private var activeSessionStore = ActiveSessionStore.shared
    @ObservedObject private var impromptuSessionStore = ImpromptuSessionStore.shared
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
    @State private var isSearchActive = false
    @State private var isLoadingCourses = false
    @State private var previewCourse: Course?

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
        if searchText.isEmpty {
            results = base
        } else {
            let query = searchText.lowercased()
            results = base.filter {
                $0.courseName.lowercased().contains(query) ||
                $0.region.lowercased().contains(query) ||
                $0.places.contains(where: { $0.placeName.lowercased().contains(query) })
            }
        }

        return results.sorted { $0.likeCount > $1.likeCount }
    }

    // 지도에 찍을 코스 마커 (대표 장소 기준, 태그별 핀 + 코스명 라벨)
    private var courseMarkers: [GoogleMapMarker] {
        filteredCourses.compactMap { course in
            guard let main = course.mainPlace else { return nil }
            return GoogleMapMarker(
                id: course.courseId,
                coordinate: main.coordinate,
                pinImageName: Self.pinImageName(for: course.tag),
                label: course.courseName
            )
        }
    }

    private static func pinImageName(for tag: CourseTag) -> String {
        switch tag {
        case .couple:  return "pin_couple"
        case .family:  return "pin_family"
        case .solo:    return "pin_solo"
        case .friends: return "pin_friends"
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer

            if !searchText.isEmpty && filteredCourses.isEmpty {
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
                        Text("코스 불러오는 중...")
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

            topBar
            locationButton
            if previewCourse == nil {
                createCourseButton
            }
            if let course = previewCourse {
                CoursePreviewCard(course: course) {
                    withAnimation(.spring(response: 0.3)) { previewCourse = nil }
                    selectedCourse = course
                } onDismiss: {
                    withAnimation(.spring(response: 0.3)) { previewCourse = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
                .padding(.bottom, 83)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: previewCourse == nil)
        .ignoresSafeArea()
        .task {
            isLoadingCourses = true
            await courseService.fetchCourses(blockedUserIds: userService.currentUser?.blockedUserIds ?? [])
            if let uid = authService.currentUser?.uid {
                await courseService.fetchLikedCourseIds(userId: uid)
            }
            isLoadingCourses = false
            locationService.requestPermission()
            locationService.startTracking(places: [])
            if let coord = locationService.currentLocation?.coordinate {
                await moveToCountry(coord: coord)
            }
        }
        .onChange(of: locationService.currentLocation) { _, location in
            guard !didMoveToUser, let coord = location?.coordinate else { return }
            Task { await moveToCountry(coord: coord) }
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
    }

    // MARK: - Map
    private var mapLayer: some View {
        GoogleMapView(
            markers: courseMarkers,
            showsUserLocation: true,
            initialCamera: gmsCamera(center: CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8), latDelta: 5),
            cameraCommand: $cameraCommand,
            onMarkerTap: { courseId in
                guard let course = filteredCourses.first(where: { $0.courseId == courseId }) else { return }
                if activeSessionStore.hasTodaySession {
                    pendingNewCourse = course
                    showCourseResumeSheet = true
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        previewCourse = course
                    }
                }
            }
        )
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
                        
                        TextField("코스 검색 · 엔터로 지역 이동", text: $searchText)
                            .font(.tte(14))
                            .foregroundColor(.tteDarkGray)
                            .autocorrectionDisabled()
                            .onSubmit {
                                Task { await performMapSearch() }
                            }
                        
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.tteMediumGray)
                            }
                            .accessibilityLabel("검색어 지우기")
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
                        .accessibilityLabel("지역 검색")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: buttonSize)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)

                    // 코스 필터
                    HStack(spacing: 0) {
                        ForEach([
                            ("square.grid.2x2.fill", CourseFilter.all,   "전체 코스"),
                            ("heart.fill",            .liked, "찜한 코스"),
                            ("person.fill",           .mine,  "내 코스")
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
            .padding(.top, 56)

            Spacer()
        }
    }

    // MARK: - 나라 크기에 맞는 줌 레벨로 이동
    private func moveToCountry(coord: CLLocationCoordinate2D) async {
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        let countryCode = placemarks?.first?.isoCountryCode ?? ""
        let delta = countrySpan(for: countryCode)
        await MainActor.run {
            didMoveToUser = true
            cameraCommand = gmsCamera(center: coord, latDelta: delta)
        }
    }

    private func countrySpan(for isoCode: String) -> Double {
        switch isoCode {
        // 소형 국가
        case "SG", "MC", "LI", "SM", "VA", "MV", "BH", "HK", "MO": return 0.5
        // 소~중형 국가
        case "KR", "JP", "GB", "DE", "FR", "IT", "ES", "NL", "BE",
             "CH", "AT", "CZ", "SK", "HU", "PT", "SE", "NO", "DK",
             "FI", "PL", "GR", "TH", "VN", "MY", "PH", "NZ", "TW": return 8
        // 중형 국가
        case "MX", "SA", "IR", "MN", "ID", "PE", "CO", "ZA", "EG",
             "TR", "NG", "ET", "TZ", "KZ": return 20
        // 대형 국가
        case "US", "CN", "RU", "CA", "BR", "AU", "IN", "AR": return 40
        default: return 10
        }
    }

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
                Text("진행 중인 코스가 있어요")
                    .font(.tte(20, .bold))
                    .foregroundColor(.tteDarkGray)
                if let saved {
                    Text("\(saved.course.courseName) · \(saved.visitedPlaceOrders.count)/\(saved.orderedPlaces.count)곳 완료")
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
                        Text("이어서 기록하기").font(.tte(16, .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }

                // 새로 시작하기 — 세션 삭제 후 홈으로
                Button {
                    showCourseResumeSheet = false
                    pendingNewCourse = nil
                    ActiveSessionStore.shared.clear()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise").font(.tte(15))
                        Text("새로 시작하기")
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
            ZStack {
                // 나의 오늘 — 정중앙 고정
                Button {
                    handleImpromptuTap()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "figure.walk")
                            .font(.tte(17, .semibold))
                        Text("나의 오늘")
                            .font(.tte(17, .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(
                        Capsule()
                            .fill(Color.tteOrange)
                            .shadow(color: .tteOrange.opacity(0.45), radius: 12, y: 4)
                    )
                }

                // 좌측 — 이어하기 버튼들
                HStack {
                    HStack(spacing: 10) {
                        // 나의 오늘 이어하기
                        if impromptuSessionStore.hasTodaySession,
                           let saved = ImpromptuSessionStore.shared.loadTodaySession() {
                            Button {
                                courseSessionInfo = nil
                                impromptuRoomIds = Set(saved.roomIds)
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: "figure.walk")
                                        .font(.tte(16, .semibold))
                                    Text("이어하기")
                                        .font(.tte(9, .medium))
                                }
                                .foregroundColor(.tteOrange)
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(Color.tteBackground).shadow(color: .black.opacity(0.15), radius: 8, y: 2))
                            }
                        }

                        // 코스 이어하기
                        if activeSessionStore.hasTodaySession {
                            Button {
                                pendingNewCourse = nil
                                showCourseResumeSheet = true
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: "map.fill")
                                        .font(.tte(16, .semibold))
                                    Text("코스")
                                        .font(.tte(9, .medium))
                                }
                                .foregroundColor(.tteOrange)
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(Color.tteBackground).shadow(color: .black.opacity(0.15), radius: 8, y: 2))
                            }
                        }
                    }
                    .padding(.leading, 24)
                    Spacer()
                }

                // 현재 위치 — 나의 오늘 우측에 독립 배치
                HStack {
                    Spacer()
                    Button {
                        guard let coord = locationService.currentLocation?.coordinate else { return }
                        cameraCommand = gmsCamera(center: coord, latDelta: 0.05)
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.tte(18, .medium))
                            .foregroundColor(.tteOrange)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Color.tteBackground).shadow(color: .black.opacity(0.15), radius: 8, y: 2))
                    }
                    .accessibilityLabel("현재 위치로 이동")
                    .padding(.trailing, 24)
                }
            }
            .padding(.bottom, 104)
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
                    Text(course.tag.rawValue)
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
                        Text("\(course.places.count)곳")
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
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.tte(40))
                .foregroundColor(.tteOrange.opacity(0.6))
            
            Text("검색 결과가 없어요")
                .font(.tte(17, .bold))
                .foregroundColor(.tteDarkGray)
            
            Text("다른 키워드로 검색해보세요!")
                .font(.tte(14))
                .foregroundColor(.tteMediumGray)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
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
        let svc = PlaceSearchService()
        await svc.search(q)
        if let first = svc.results.first {
            cameraCommand = gmsCamera(
                center: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                latDelta: 0.1
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
    let onTap: () -> Void
    let onDismiss: () -> Void
    @State private var isAuthorVerified = false
    @State private var authorNickname: String = ""
    @EnvironmentObject private var userService: UserService

    var body: some View {
        VStack(spacing: 0) {
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
                    .accessibilityLabel("미리보기 닫기")
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 10)
            .padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(course.places.sorted { $0.order < $1.order }) { place in
                        PlacePhotoThumbnail(place: place)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 130)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(course.courseName)
                            .font(.tte(16, .bold))
                            .foregroundColor(.tteDarkGray)
                            .lineLimit(1)
                        if isAuthorVerified {
                            VerifiedBadge(creatorLabel: nil)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(course.tag.rawValue)
                            .font(.tte(11, .semibold))
                            .foregroundColor(.tteOrange)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.tteOrange.opacity(0.12)))
                        if isAuthorVerified {
                            Text(authorNickname)
                                .font(.tte(11, .medium))
                                .foregroundColor(.tteOrange.opacity(0.8))
                        }
                        Text("장소 \(course.places.count)개")
                            .font(.tte(12))
                            .foregroundColor(.tteMediumGray)
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill").font(.tte(11))
                            Text("\(course.likeCount)").font(.tte(12))
                        }
                        .foregroundColor(.tteMediumGray)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.tte(14, .semibold))
                    .foregroundColor(.tteOrange)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.tteBackground)
                .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
        )
        .onTapGesture { onTap() }
        .task {
            let author = await userService.fetchAuthor(uid: course.authorId)
            isAuthorVerified = author?.isVerified ?? false
            authorNickname = author?.nickname ?? ""
        }
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
    MainView()
        .environmentObject(AuthService())
        .environmentObject(CourseService())
}
