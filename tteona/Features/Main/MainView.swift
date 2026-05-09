import SwiftUI
import MapKit

struct MainView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var notificationManager: AppNotificationManager
    @StateObject private var locationService = LocationService()
    @State private var selectedCourse: Course?
    @State private var impromptuRoomIds: Set<String>? = nil
    @State private var resumeActiveSession: Set<String>? = nil
    @State private var hasSavedImpromptuSession = false
    @State private var hasSavedCourseSession = false
    @State private var showRoomSelect = false
    @State private var selectedRoomIds: Set<String> = []
    @State private var searchedRegionName: String? = nil
    @State private var showRegionSearch = false
    @State private var courseFilter: CourseFilter = .all

    enum CourseFilter { case all, liked, mine }
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8),
        span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
    )
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8),
            span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
        )
    )

    private var filteredCourses: [Course] {
        switch courseFilter {
        case .all:   return courseService.courses
        case .liked: return courseService.courses.filter { courseService.likedCourseIds.contains($0.courseId) }
        case .mine:  return courseService.courses.filter { $0.authorId == authService.currentUser?.uid }
        }
    }

    private var visibleCourses: [Course] {
        filteredCourses.filter { course in
            guard let first = course.places.first else { return false }
            return mapRegion.contains(first.coordinate)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            topBar
            locationButton
            createCourseButton
        }
        .ignoresSafeArea()
        .onAppear {
            refreshSessionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshSessionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeSessionDidChange)) { _ in
            refreshSessionState()
        }
        .task {
            await courseService.fetchCourses()
            if let uid = authService.currentUser?.uid {
                await courseService.fetchLikedCourseIds(userId: uid)
            }
            locationService.requestPermission()
            locationService.startTracking(places: [])
            if let coord = locationService.currentLocation?.coordinate {
                await moveToCountry(coord: coord)
            }
        }
        .onChange(of: locationService.currentLocation) { _, location in
            guard mapRegion.center.latitude == 36.5,
                  mapRegion.center.longitude == 127.8,
                  let coord = location?.coordinate else { return }
            Task { await moveToCountry(coord: coord) }
        }
        .sheet(item: $selectedCourse, onDismiss: refreshSessionState) { course in
            CourseDetailView(course: course)
                .environmentObject(authService)
                .environmentObject(courseService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .sheet(isPresented: $showRegionSearch) {
            RegionSearchView { name, coord in
                searchedRegionName = name
                withAnimation {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))
                }
            }
        }
        .fullScreenCover(isPresented: $showRoomSelect) {
            RoomSelectView(selectedRoomIds: $selectedRoomIds) {
                let confirmed = selectedRoomIds
                showRoomSelect = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    impromptuRoomIds = confirmed
                }
            }
            .environmentObject(roomService)
        }
        .fullScreenCover(item: $impromptuRoomIds, onDismiss: refreshSessionState) { roomIds in
            ImpromptuSessionView(selectedRoomIds: roomIds) {
                impromptuRoomIds = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showRoomSelect = true
                }
            }
            .environmentObject(authService)
            .environmentObject(userService)
            .environmentObject(courseService)
            .environmentObject(roomService)
        }
        .fullScreenCover(item: $resumeActiveSession, onDismiss: refreshSessionState) { roomIds in
            if let saved = ActiveSessionStore.shared.loadTodaySession() {
                ActiveSessionView(course: saved.course, roomIds: roomIds)
                    .environmentObject(AppNotificationManager.shared)
                    .environmentObject(authService)
                    .environmentObject(userService)
                    .environmentObject(roomService)
            }
        }
        .onChange(of: notificationManager.shouldOpenTodaySession) { _, should in
            guard should else { return }
            notificationManager.shouldOpenTodaySession = false
            handleImpromptuTap()
        }
    }

    // MARK: - Map
    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            ForEach(visibleCourses) { course in
                if let first = course.places.first {
                    Annotation(course.courseName, coordinate: first.coordinate) {
                        CourseMapPin(course: course)
                            .onTapGesture {
                                withAnimation { selectedCourse = course }
                            }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .onMapCameraChange { context in
            mapRegion = context.region
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack {
            GeometryReader { geo in
                let spacing: CGFloat = 12
                let buttonSize: CGFloat = 40

                HStack(spacing: 0) {
                    // 지역 검색 버튼
                    Button {
                        showRegionSearch = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14, weight: .medium))
                            if let name = searchedRegionName {
                                Text(name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.tteMediumGray)
                                    .onTapGesture {
                                        searchedRegionName = nil
                                        cameraPosition = .region(MKCoordinateRegion(
                                            center: CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8),
                                            span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
                                        ))
                                    }
                            }
                        }
                        .foregroundColor(searchedRegionName != nil ? .tteOrange : .tteDarkGray)
                        .frame(width: searchedRegionName != nil ? nil : buttonSize, height: buttonSize)
                        .padding(.horizontal, searchedRegionName != nil ? 12 : 0)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    }

                    Spacer()

                    // 코스 필터
                    HStack(spacing: 0) {
                        ForEach([("전체", CourseFilter.all), ("좋아요", .liked), ("내 코스", .mine)], id: \.0) { label, filter in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { courseFilter = filter }
                            } label: {
                                Text(label)
                                    .font(.system(size: 13, weight: courseFilter == filter ? .semibold : .regular))
                                    .foregroundColor(courseFilter == filter ? .white : .primary.opacity(0.7))
                                    .padding(.horizontal, 16)
                                    .frame(height: buttonSize)
                                    .background(Capsule().fill(courseFilter == filter ? Color.tteOrange : Color.clear))
                            }
                        }
                    }
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)

                    Spacer()

                    // 균형을 위한 더미 (검색 버튼과 동일 너비)
                    Color.clear.frame(width: buttonSize, height: buttonSize)
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
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
                ))
            }
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

    private func refreshSessionState() {
        let impromptu = ImpromptuSessionStore.shared.loadTodaySession()
        hasSavedImpromptuSession = impromptu.map { !$0.places.isEmpty } ?? false
        hasSavedCourseSession = ActiveSessionStore.shared.loadTodaySession() != nil
    }

    private func handleImpromptuTap() {
        selectedRoomIds = []
        let saved = ImpromptuSessionStore.shared.loadTodaySession()
        let hasSavedSession = saved.map { !$0.places.isEmpty } ?? false
        if hasSavedSession || roomService.myRooms.isEmpty {
            // 저장된 세션이 있으면 기존 roomIds 복원, 없으면 빈 set으로 시작
            impromptuRoomIds = Set(saved?.roomIds ?? [])
        } else {
            showRoomSelect = true
        }
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
                            .font(.system(size: 17, weight: .semibold))
                        Text("나의 오늘")
                            .font(.system(size: 17, weight: .bold))
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
                        if hasSavedImpromptuSession,
                           let saved = ImpromptuSessionStore.shared.loadTodaySession() {
                            Button {
                                impromptuRoomIds = Set(saved.roomIds)
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: "figure.walk")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("이어하기")
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundColor(.tteOrange)
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(Color.tteBackground).shadow(color: .black.opacity(0.15), radius: 8, y: 2))
                            }
                        }

                        // 코스 이어하기
                        if hasSavedCourseSession,
                           let saved = ActiveSessionStore.shared.loadTodaySession() {
                            Button {
                                resumeActiveSession = Set(saved.roomIds)
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: "map.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("이어하기")
                                        .font(.system(size: 9, weight: .medium))
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
                        withAnimation {
                            cameraPosition = .region(MKCoordinateRegion(
                                center: coord,
                                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                            ))
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.tteOrange)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Color.tteBackground).shadow(color: .black.opacity(0.15), radius: 8, y: 2))
                    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
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
            }
            Text(course.courseName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.tteDarkGray)
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.tteMediumGray)
                    .font(.system(size: 13))
                Text("\(course.places.count)곳")
                    .font(.system(size: 13))
                    .foregroundColor(.tteMediumGray)
                Spacer()
                Image(systemName: "heart.fill")
                    .foregroundColor(.red.opacity(0.8))
                    .font(.system(size: 13))
                Text("\(course.likeCount)")
                    .font(.system(size: 13))
                    .foregroundColor(.tteMediumGray)
            }
        }
        .padding(16)
        .frame(width: 220)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemBackground)))
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

#Preview {
    MainView()
        .environmentObject(AuthService())
        .environmentObject(CourseService())
}
