import SwiftUI
import PhotosUI
import CoreLocation

// MARK: - 프로필 탭 (나만의 공간)
/// 인스타그램식 마지막 탭 — 내 프로필 + 발자취 지도 + 여행 기록.
/// 설정은 우상단 톱니로 편입, 유저 검색은 우상단 돋보기.
struct ProfileTabView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var roomService: RoomService
    @ObservedObject private var footprintService = FootprintService.shared

    @State private var footprints: [FootprintRecord] = []
    @State private var stats: TravelStats?
    @State private var isLoaded = false

    // 내 코스 + 썸네일 (프로필에서 직접 썸네일 꾸미기 + 탭하면 상세)
    @State private var myCourses: [Course] = []
    @State private var thumbnails: [String: String] = [:]
    @State private var selectedCourse: Course? = nil
    // 탭한 코스가 상세로 열릴 때까지 해당 카드에만 로딩 인디케이터를 띄운다
    @State private var openingCourseId: String? = nil

    // 발자취 지도 연출
    @State private var focusCommand: FootprintMapFocus? = nil
    @State private var highlightCodes: Set<String> = []
    @State private var greetingText: String? = nil
    @State private var showFullMap = false

    // 프로필 편집
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false
    @State private var showNicknameEdit = false

    // 툴바 네비게이션 (프로그래매틱 — 시각 검증 아규먼트로도 진입 가능)
    @State private var showSearch = false
    @State private var showSettings = false

    private let oneShotLocation = OneShotLocation()

    private var summary: FootprintSummary { footprintService.mySummary }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    header
                    statsStrip
                    footprintSection
                    coursesSection
                    timelineSection
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color.tteBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.tte(16, .semibold))
                            .foregroundColor(.tteDarkGray)
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.tte(16, .semibold))
                            .foregroundColor(.tteDarkGray)
                    }
                }
            }
            .navigationDestination(isPresented: $showSearch) { UserSearchView() }
            .navigationDestination(isPresented: $showSettings) { SettingsView() }
        }
        .sheet(isPresented: $showNicknameEdit) {
            NicknameEditSheet()
                .environmentObject(authService)
                .environmentObject(userService)
        }
        .sheet(item: $selectedCourse, onDismiss: { openingCourseId = nil }) { course in
            CourseDetailView(course: course)
                .environmentObject(authService)
                .environmentObject(courseService)
                .environmentObject(userService)
                .environmentObject(roomService)
                .onAppear { openingCourseId = nil }
        }
        .fullScreenCover(isPresented: $showFullMap) {
            FootprintFullMapView(
                summary: summary,
                routes: footprints.map(\.points),
                initialFocus: homeFocus,
                subtitle: progressText
            )
        }
        .task { await load() }
        .onChange(of: footprintService.mySummary) { _, _ in
            // 브이로그 생성 직후 탭 전환 시 새 지역 연출
            playNewRegionRevealIfNeeded()
        }
    }

    // MARK: - 데이터 로드

    private func load() async {
        #if DEBUG
        // 시각 검증용: 검색/설정 화면 바로 진입
        if ProcessInfo.processInfo.arguments.contains("-previewUserSearch") { showSearch = true }
        if ProcessInfo.processInfo.arguments.contains("-previewSettings") { showSettings = true }
        // 시각 검증용: 가짜 발자취 데이터 주입 (-previewFootprintDemo)
        if ProcessInfo.processInfo.arguments.contains("-previewFootprintDemo"), !isLoaded {
            await loadDemoFootprints()
            isLoaded = true
            // 세계 뷰 렌더링 검증 (-previewWorldFocus)
            if ProcessInfo.processInfo.arguments.contains("-previewWorldFocus") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                focusCommand = .world
            }
            // 일본 주/도 검증 (-previewJapanFocus) — 오사카부만 칠해지는지
            if ProcessInfo.processInfo.arguments.contains("-previewJapanFocus") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                focusCommand = .country("JPN")
            }
            // 전체화면 지도 검증 (-previewFullMap)
            if ProcessInfo.processInfo.arguments.contains("-previewFullMap") {
                try? await Task.sleep(nanoseconds: 800_000_000)
                showFullMap = true
            }
            return
        }
        #endif
        guard let uid = authService.currentUser?.uid else { return }
        if !isLoaded {
            // 1) 요약 먼저 로드 → 2) 과거 코스 백필(1회, mySummary 즉시 갱신) → 3) 나머지 병렬 조회
            _ = await footprintService.fetchSummary(userId: uid, isMe: true)
            await footprintService.backfillFromMyCourses(userId: uid)

            async let recordsTask = footprintService.fetchFootprints(userId: uid)   // 백필 후 재조회 → 과거 코스 포함
            async let statsTask = StatsService.shared.fetchMyStats(userId: uid)
            async let coursesTask = footprintService.fetchCourses(authorId: uid)
            async let thumbsTask = CourseThumbnailService.shared.fetchAllThumbnails()
            footprints = await recordsTask
            stats = await statsTask
            myCourses = await coursesTask
            thumbnails = await thumbsTask
            isLoaded = true
            playNewRegionRevealIfNeeded()
            if highlightCodes.isEmpty { await greetIfTravelling() }
        } else {
            footprints = await footprintService.fetchFootprints(userId: uid)
            stats = await StatsService.shared.fetchMyStats(userId: uid)
            myCourses = await footprintService.fetchCourses(authorId: uid)
        }
    }

    #if DEBUG
    /// 시뮬레이터 시각 검증용 가짜 데이터 — 서울 일부 + 지방 도시 + 일본/태국 방문 가정
    private func loadDemoFootprints() async {
        await Task.detached(priority: .userInitiated) {
            FootprintAtlas.shared.ensureLoaded()
        }.value
        let atlas = FootprintAtlas.shared
        let demoNames = ["종로구", "중구", "용산구", "성동구", "마포구", "강남구",
                         "강릉시", "전주시", "경주시", "제주시", "서귀포시", "속초시", "여수시"]
        let sigs = atlas.koreaRegions.filter { demoNames.contains($0.name) }.map(\.code)
        footprintService.mySummary = FootprintSummary(
            sigCodes: Set(sigs),
            provinceCodes: ["JP-27", "TH-10"],   // 오사카부 · 방콕 (해외는 주/도만 색칠)
            countryCodes: ["KOR", "JPN", "THA"]
        )
        footprints = [
            FootprintRecord(id: "demo1", courseId: "c1", courseName: "성수동 감성 카페 투어",
                            date: Date(), placeCount: 4,
                            sigCodes: [], provinceCodes: [], countryCodes: ["KOR"],
                            regionNames: ["서울 성동구"],
                            points: [FootprintPoint(lat: 37.5446, lng: 127.0559),
                                     FootprintPoint(lat: 37.5479, lng: 127.0473),
                                     FootprintPoint(lat: 37.5512, lng: 127.0410)]),
            FootprintRecord(id: "demo2", courseId: "c2", courseName: "강릉 바다 브이로그",
                            date: Date().addingTimeInterval(-86400 * 12), placeCount: 5,
                            sigCodes: [], provinceCodes: [], countryCodes: ["KOR"],
                            regionNames: ["강릉시"],
                            points: [FootprintPoint(lat: 37.7710, lng: 128.9473),
                                     FootprintPoint(lat: 37.7896, lng: 128.9174),
                                     FootprintPoint(lat: 37.8054, lng: 128.8961)]),
            FootprintRecord(id: "demo3", courseId: "c3", courseName: "오사카 먹방 여행",
                            date: Date().addingTimeInterval(-86400 * 40), placeCount: 6,
                            sigCodes: [], provinceCodes: ["JP-27"], countryCodes: ["JPN"],
                            regionNames: ["Ōsaka"],
                            points: [FootprintPoint(lat: 34.6687, lng: 135.5010),
                                     FootprintPoint(lat: 34.6525, lng: 135.5060)])
        ]
        myCourses = [
            Course(courseId: "c1", authorId: "me", courseName: "성수동 감성 카페 투어",
                   tag: .friends, region: "서울", likeCount: 12, createdAt: Date(),
                   places: [Place(order: 1, placeName: "대림창고", latitude: 37.5446, longitude: 127.0559)]),
            Course(courseId: "c2", authorId: "me", courseName: "강릉 바다 브이로그",
                   tag: .couple, region: "강릉", likeCount: 34, createdAt: Date(),
                   places: [Place(order: 1, placeName: "안목해변", latitude: 37.7710, longitude: 128.9473)])
        ]
    }
    #endif

    /// 새로 칠해진 지역이 있으면: 그 지역으로 날아가 펄스 하이라이트 (브이로그 완성의 보상 연출)
    private func playNewRegionRevealIfNeeded() {
        let newCodes = footprintService.lastNewCodes
        guard !newCodes.isEmpty else { return }
        let primary = footprintService.lastPrimaryNewCode
        footprintService.lastNewCodes = []
        footprintService.lastPrimaryNewCode = nil
        highlightCodes = newCodes
        greetingText = L("footprint.newRegion")
        // 대표(최다 체류) 신규 지역으로 카메라 이동 — 없으면 시군구 우선 폴백
        let target = primary ?? newCodes.first(where: { $0.count == 5 }) ?? newCodes.first
        if let code = target, code.count == 5,
           let region = FootprintAtlas.shared.koreaRegion(code: code) {
            focusCommand = .point(lat: latOf(region.center), lng: lngOf(region.center))
        } else if let code = target, code.count == 3 {
            focusCommand = .country(code)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            withAnimation(.easeOut(duration: 0.6)) {
                highlightCodes = []
                greetingText = nil
            }
        }
    }

    /// 현재 위치가 홈과 다른 나라·지역이면 "지금 여기 있네요" 안내 후 카메라 이동
    private func greetIfTravelling() async {
        guard let location = await oneShotLocation.requestIfAuthorized() else { return }
        let resolved = await Task.detached(priority: .utility) {
            FootprintAtlas.shared.resolve(lat: location.coordinate.latitude,
                                          lng: location.coordinate.longitude)
        }.value
        guard let region = resolved.sig ?? resolved.province else { return }

        // 홈(가장 많이 기록된 나라)과 현재 국가가 다르면 여행 중
        let currentCountry = resolved.countryCode
        let home = homeCountryCode
        let travelling = currentCountry != nil && currentCountry != home
        // 아직 안 칠한 지역(시군구/주도)이면 안내
        let unpainted = resolved.sig.map { !summary.sigCodes.contains($0.code) }
            ?? (resolved.province.map { !summary.provinceCodes.contains($0.code) } ?? false)
        guard travelling || unpainted else { return }

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let name = LanguageManager.shared.language == .korean ? region.name : (region.nameEng ?? region.name)
        withAnimation(.spring(duration: 0.5)) {
            greetingText = L("footprint.greeting", name)
        }
        focusCommand = .point(lat: location.coordinate.latitude, lng: location.coordinate.longitude)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation(.easeOut(duration: 0.6)) { greetingText = nil }
        }
    }

    /// 홈 국가 — 발자취에서 가장 많이 기록된 나라, 없으면 시스템 지역
    private var homeCountryCode: String {
        var counts: [String: Int] = [:]
        for record in footprints {
            for code in record.countryCodes { counts[code, default: 0] += 1 }
        }
        if let top = counts.max(by: { $0.value < $1.value })?.key { return top }
        let alpha2 = Locale.current.region?.identifier ?? "KR"
        if alpha2 == "KR" { return "KOR" }
        // ISO2 → ISO3 매핑: 해당 국가의 주/도 코드(ISO 3166-2, "US-CA")가 alpha2로 시작
        return FootprintAtlas.shared.worldProvinces
            .first { $0.code.hasPrefix(alpha2 + "-") }?.country ?? "KOR"
    }

    private var homeFocus: FootprintMapFocus {
        homeCountryCode == "KOR" ? .korea : .country(homeCountryCode)
    }

    private func latOf(_ unit: CGPoint) -> Double {
        atan(sinh(.pi * (1 - 2 * Double(unit.y)))) * 180 / .pi
    }
    private func lngOf(_ unit: CGPoint) -> Double { Double(unit.x) * 360 - 180 }

    // MARK: - 헤더

    private var header: some View {
        VStack(spacing: 14) {
            PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                ZStack {
                    Circle()
                        .fill(Color.tteOrange.opacity(0.12))
                        .frame(width: 84, height: 84)
                    if let urlString = userService.currentUser?.profileImageUrl,
                       let url = URL(string: urlString) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            initialLetter
                        }
                        .frame(width: 84, height: 84)
                        .clipShape(Circle())
                    } else {
                        initialLetter
                    }
                    if isUploadingAvatar {
                        Circle().fill(Color.black.opacity(0.4)).frame(width: 84, height: 84)
                        ProgressView().tint(.white)
                    }
                    Image(systemName: "camera.fill")
                        .font(.tte(11, .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.tteOrange))
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .offset(x: 30, y: 30)
                }
            }
            .disabled(isUploadingAvatar)
            .onChange(of: avatarPickerItem) { _, newItem in
                Task { await uploadAvatar(from: newItem) }
            }

            Button {
                showNicknameEdit = true
            } label: {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(userService.currentUser?.nickname.isEmpty == false
                             ? userService.currentUser!.nickname : L("settings.noNickname"))
                            .font(.tte(21, .bold))
                            .foregroundColor(.tteDarkGray)
                        if userService.currentUser?.isVerified == true {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.tte(15))
                                .foregroundColor(.tteOrange)
                        }
                        Image(systemName: "pencil")
                            .font(.tte(12, .semibold))
                            .foregroundColor(.tteMediumGray)
                    }
                    if let label = userService.currentUser?.creatorLabel, !label.isEmpty {
                        Text(label)
                            .font(.tte(12, .semibold))
                            .foregroundColor(.tteOrange)
                    }
                    Text(authService.currentUser?.email ?? "")
                        .font(.tte(12))
                        .foregroundColor(.tteMediumGray)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private var initialLetter: some View {
        Text(String(userService.currentUser?.nickname.prefix(1) ?? "?"))
            .font(.tte(32, .semibold))
            .foregroundColor(.tteOrange)
    }

    private func uploadAvatar(from item: PhotosPickerItem?) async {
        guard let item, let uid = authService.currentUser?.uid else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        if let url = await ProfileImageService.shared.upload(uid: uid, image: image) {
            userService.setProfileImageUrl(url)
        }
    }

    // MARK: - 통계 스트립

    private var statsStrip: some View {
        NavigationLink {
            TravelStatsView()
                .environmentObject(authService)
        } label: {
            HStack(spacing: 0) {
                statCell(value: stats.map { "\($0.coursesCreated)" } ?? "–",
                         label: L("profile.stats.courses"))
                divider
                statCell(value: stats.map { "\($0.likesReceived)" } ?? "–",
                         label: L("profile.stats.likes"))
                divider
                statCell(value: "\(summary.sigCodes.count)",
                         label: L("profile.stats.regions"))
                divider
                statCell(value: "\(summary.countryCodes.count)",
                         label: L("profile.stats.countries"))
            }
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(UIColor.separator).opacity(0.4))
            .frame(width: 1, height: 26)
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.tte(18, .bold))
                .foregroundColor(.tteDarkGray)
            Text(label)
                .font(.tte(11))
                .foregroundColor(.tteMediumGray)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 발자취 지도 섹션

    private var footprintSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("footprint.title"))
                    .font(.tte(18, .bold))
                    .foregroundColor(.tteDarkGray)
                Spacer()
                Text(progressText)
                    .font(.tte(12, .semibold))
                    .foregroundColor(.tteOrange)
            }
            .padding(.horizontal, 20)

            ZStack(alignment: .top) {
                FootprintMapView(
                    summary: summary,
                    routes: footprints.map(\.points),
                    highlightCodes: highlightCodes,
                    interactive: true,
                    panZoom: false,   // 페이지 스크롤과 충돌 방지 — 탭만
                    initialFocus: homeFocus,
                    focusCommand: focusCommand
                )
                .frame(height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color(hex: "#E8E2D6"), lineWidth: 1)
                )
                // 전체화면 확대 버튼 (우상단) — 여기서만 팬/핀치로 세계지도를 자유 탐색
                .overlay(alignment: .topTrailing) {
                    Button {
                        showFullMap = true
                    } label: {
                        ZStack {
                            Circle().fill(Color.black.opacity(0.45)).frame(width: 34, height: 34)
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.tte(14, .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(12)
                }

                if let greeting = greetingText {
                    greetingBanner(greeting)
                        .padding(.top, -14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .padding(.horizontal, 20)

            koreaProgressBar
                .padding(.horizontal, 20)

            if summary.isEmpty {
                emptyFootprintHint
                    .padding(.horizontal, 20)
            }
        }
    }

    private var progressText: String {
        L("footprint.subtitle", summary.sigCodes.count, summary.countryCodes.count)
    }

    /// 한국 시군구 채움률 게이지 — "지도를 다 칠하고 싶다"는 수집 동기의 핵심 장치
    private var koreaProgressBar: some View {
        let total = max(FootprintAtlas.shared.koreaRegions.count, 250)
        let filled = summary.sigCodes.count
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(hex: "#EFEAE1"))
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: "#FF8B5E"), .tteOrange],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * CGFloat(filled) / CGFloat(total),
                                          filled > 0 ? 10 : 0))
                }
            }
            .frame(height: 8)
            HStack {
                Text(L("footprint.koreaProgress", filled, total))
                    .font(.tte(11))
                    .foregroundColor(.tteMediumGray)
                Spacer()
                Text(String(format: "%.1f%%", Double(filled) / Double(total) * 100))
                    .font(.tte(11, .semibold))
                    .foregroundColor(.tteOrange)
            }
        }
    }

    private var emptyFootprintHint: some View {
        HStack(spacing: 12) {
            Image("tteoni-wink")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
            Text(L("footprint.empty"))
                .font(.tte(13))
                .foregroundColor(.tteMediumGray)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.tteOrange.opacity(0.07))
        )
    }

    private func greetingBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image("tteoni-wink")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
            Text(text)
                .font(.tte(13, .semibold))
                .foregroundColor(.tteDarkGray)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.white)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        )
    }

    // MARK: - 내 코스 (썸네일 꾸미기)

    private let courseColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    @ViewBuilder
    private var coursesSection: some View {
        if !myCourses.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(L("profile.myCourses"))
                        .font(.tte(18, .bold))
                        .foregroundColor(.tteDarkGray)
                    Image(systemName: "photo.badge.plus")
                        .font(.tte(13))
                        .foregroundColor(.tteMediumGray)
                    Spacer()
                }
                .padding(.horizontal, 20)

                Text(L("profile.myCourses.hint"))
                    .font(.tte(12))
                    .foregroundColor(.tteMediumGray)
                    .padding(.horizontal, 20)

                LazyVGrid(columns: courseColumns, spacing: 10) {
                    ForEach(myCourses, id: \.courseId) { course in
                        EditableCourseCard(
                            course: course,
                            thumbnailURL: thumbnails[course.courseId],
                            isOpening: openingCourseId == course.courseId,
                            onTap: {
                                Haptics.light()
                                openingCourseId = course.courseId
                                selectedCourse = course
                            },
                            onThumbnailChanged: { newURL in
                                // 업로드 성공 → 서버 캐시버스트 URL로 즉시 교체 (탐색탭과 동일 URL)
                                thumbnails[course.courseId] = newURL
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - 여행 기록 타임라인

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !footprints.isEmpty {
                Text(L("footprint.timeline"))
                    .font(.tte(18, .bold))
                    .foregroundColor(.tteDarkGray)
                    .padding(.horizontal, 20)

                VStack(spacing: 0) {
                    ForEach(Array(footprints.prefix(20).enumerated()), id: \.element.id) { index, record in
                        timelineRow(record, isLast: index == min(footprints.count, 20) - 1)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func timelineRow(_ record: FootprintRecord, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // 타임라인 축
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.tteOrange)
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)
                if !isLast {
                    Rectangle()
                        .fill(Color.tteOrange.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(record.courseName)
                    .font(.tte(15, .semibold))
                    .foregroundColor(.tteDarkGray)
                Text(Self.dateFormatter.string(from: record.date))
                    .font(.tte(12))
                    .foregroundColor(.tteMediumGray)
                if !record.regionNames.isEmpty {
                    FlowChips(names: record.regionNames)
                }
            }
            .padding(.bottom, isLast ? 0 : 20)
            Spacer()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = LanguageManager.shared.locale
        f.dateStyle = .medium
        return f
    }()
}

// MARK: - 편집 가능한 코스 카드 (내 프로필 전용 — 썸네일 직접 교체)
private struct EditableCourseCard: View {
    let course: Course
    let thumbnailURL: String?
    var isOpening: Bool = false
    var onTap: (() -> Void)? = nil
    let onThumbnailChanged: (String) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var state: UploadState = .idle
    @State private var placePhotoURL: String?

    private enum UploadState { case idle, uploading, failed }

    var body: some View {
        // 카드 본문(탭 → 코스 상세)과 썸네일 교체 버튼을 형제로 겹친다.
        // 버튼 label 안에 PhotosPicker를 넣으면 피커가 탭을 받지 못하므로 분리했다.
        ZStack(alignment: .topTrailing) {
            Button { onTap?() } label: { cardBody }
                .buttonStyle(PressableCardStyle())
            thumbnailPicker
                .padding(8)
        }
        .onChange(of: pickerItem) { _, newItem in
            Task { await upload(newItem) }
        }
        .task {
            guard thumbnailURL == nil, placePhotoURL == nil,
                  let main = course.mainPlace else { return }
            placePhotoURL = await PlacesPhotoService.shared.photoURL(
                for: main.placeName, latitude: main.latitude, longitude: main.longitude)
        }
    }

    private var cardBody: some View {
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
                    .frame(height: 80)
                    .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(course.courseName)
                        .font(.tte(13, .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    HStack(spacing: 5) {
                        Text("\(course.region) · \(course.tag.displayName)")
                            .font(.tte(10))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            Image(systemName: "heart.fill").font(.tte(9))
                            Text("\(course.likeCount)").font(.tte(10, .semibold))
                        }
                        .foregroundColor(.white.opacity(0.95))
                    }
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                }
                .padding(9)
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
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isOpening)
    }

    // 썸네일 교체 버튼 (우상단 카메라)
    private var thumbnailPicker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            ZStack {
                Circle().fill(Color.black.opacity(0.45)).frame(width: 30, height: 30)
                if state == .uploading {
                    ProgressView().tint(.white).scaleEffect(0.7)
                } else {
                    Image(systemName: state == .failed ? "exclamationmark.triangle.fill" : "camera.fill")
                        .font(.tte(12, .semibold))
                        .foregroundColor(state == .failed ? .yellow : .white)
                }
            }
        }
        // 상세가 열리는 중에는 카드 위 딤 처리와 함께 비활성 (딤보다 위에 그려지므로 명시적으로)
        .disabled(state == .uploading || isOpening)
        .opacity(isOpening ? 0.4 : 1)
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let url = (thumbnailURL ?? placePhotoURL).flatMap(URL.init) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: DefaultCourseThumbnail(compact: true)
                default: Color(UIColor.secondarySystemBackground)
                }
            }
            .id(url)   // URL 바뀌면(캐시버스트) 강제 리로드
        } else {
            DefaultCourseThumbnail(compact: true)
        }
    }

    private func upload(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { state = .failed; return }
        state = .uploading
        if let url = await CourseThumbnailService.shared.upload(courseId: course.courseId, image: image) {
            // 서버가 ?v=timestamp 캐시버스트를 붙여 반환 → 그대로 사용하면 탐색탭·DB와 완전히 동일
            state = .idle
            onThumbnailChanged(url)
            Haptics.success()
        } else {
            state = .failed
        }
    }
}

// MARK: - 지역 이름 칩 나열
struct FlowChips: View {
    let names: [String]

    var body: some View {
        // 가로 스크롤 칩 — 지역이 많아도 행이 깨지지 않는다
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .font(.tte(11, .medium))
                        .foregroundColor(.tteOrange)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.tteOrange.opacity(0.1)))
                }
            }
        }
    }
}

// MARK: - 일회성 위치 헬퍼
/// 이미 권한이 있을 때만 위치 1회 조회 — 프로필 탭에서 맥락 없는 권한 팝업을 띄우지 않는다.
@MainActor
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    func requestIfAuthorized() async -> CLLocation? {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        if let cached = manager.location,
           Date().timeIntervalSince(cached.timestamp) < 300 {
            return cached
        }
        manager.delegate = self
        return await withCheckedContinuation { cont in
            continuation = cont
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            continuation?.resume(returning: locations.last)
            continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
}
