import SwiftUI
import PhotosUI
import CoreLocation

// MARK: - 프로필 탭 (나만의 공간)
/// 인스타그램식 마지막 탭 — 내 프로필 + 발자취 지도 + 여행 기록.
/// 설정은 우상단 톱니로 편입, 유저 검색은 우상단 돋보기.
struct ProfileTabView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @ObservedObject private var footprintService = FootprintService.shared

    @State private var footprints: [FootprintRecord] = []
    @State private var stats: TravelStats?
    @State private var isLoaded = false

    // 발자취 지도 연출
    @State private var focusCommand: FootprintMapFocus? = nil
    @State private var highlightCodes: Set<String> = []
    @State private var greetingText: String? = nil

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
            return
        }
        #endif
        guard let uid = authService.currentUser?.uid else { return }
        if !isLoaded {
            async let summaryTask: () = { _ = await footprintService.fetchSummary(userId: uid, isMe: true) }()
            async let recordsTask = footprintService.fetchFootprints(userId: uid)
            async let statsTask = StatsService.shared.fetchMyStats(userId: uid)
            _ = await summaryTask
            footprints = await recordsTask
            stats = await statsTask
            isLoaded = true
            playNewRegionRevealIfNeeded()
            if highlightCodes.isEmpty { await greetIfTravelling() }
        } else {
            footprints = await footprintService.fetchFootprints(userId: uid)
            stats = await StatsService.shared.fetchMyStats(userId: uid)
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
            countryCodes: ["KOR", "JPN", "THA"]
        )
        footprints = [
            FootprintRecord(id: "demo1", courseId: "c1", courseName: "성수동 감성 카페 투어",
                            date: Date(), placeCount: 4,
                            sigCodes: [], countryCodes: ["KOR"],
                            regionNames: ["서울 성동구"],
                            points: [FootprintPoint(lat: 37.5446, lng: 127.0559),
                                     FootprintPoint(lat: 37.5479, lng: 127.0473),
                                     FootprintPoint(lat: 37.5512, lng: 127.0410)]),
            FootprintRecord(id: "demo2", courseId: "c2", courseName: "강릉 바다 브이로그",
                            date: Date().addingTimeInterval(-86400 * 12), placeCount: 5,
                            sigCodes: [], countryCodes: ["KOR"],
                            regionNames: ["강릉시"],
                            points: [FootprintPoint(lat: 37.7710, lng: 128.9473),
                                     FootprintPoint(lat: 37.7896, lng: 128.9174),
                                     FootprintPoint(lat: 37.8054, lng: 128.8961)]),
            FootprintRecord(id: "demo3", courseId: "c3", courseName: "오사카 먹방 여행",
                            date: Date().addingTimeInterval(-86400 * 40), placeCount: 6,
                            sigCodes: [], countryCodes: ["JPN"],
                            regionNames: ["Japan"],
                            points: [FootprintPoint(lat: 34.6687, lng: 135.5010),
                                     FootprintPoint(lat: 34.6525, lng: 135.5060)])
        ]
    }
    #endif

    /// 새로 칠해진 지역이 있으면: 그 지역으로 날아가 펄스 하이라이트 (브이로그 완성의 보상 연출)
    private func playNewRegionRevealIfNeeded() {
        let newCodes = footprintService.lastNewCodes
        guard !newCodes.isEmpty else { return }
        footprintService.lastNewCodes = []
        highlightCodes = newCodes
        greetingText = L("footprint.newRegion")
        // 새 지역(시군구 우선)으로 카메라 이동
        if let sigCode = newCodes.first(where: { $0.count == 5 }),
           let region = FootprintAtlas.shared.koreaRegion(code: sigCode) {
            focusCommand = .point(lat: latOf(region.center), lng: lngOf(region.center))
        } else if let country = newCodes.first(where: { $0.count == 3 }) {
            focusCommand = .country(country)
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
        guard let region = resolved.sig ?? resolved.country else { return }

        // 홈(가장 많이 기록된 나라)과 현재 국가가 같고 한국이면 시군구 단위로만 비교
        let currentCountry = resolved.country?.code
        let home = homeCountryCode
        let travelling = currentCountry != nil && currentCountry != home
        // 국내 이동도 아직 안 칠한 지역이면 안내
        let unpainted = resolved.sig.map { !summary.sigCodes.contains($0.code) }
            ?? (currentCountry.map { !summary.countryCodes.contains($0) } ?? false)
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
        // 대부분의 ISO3는 ISO2로 시작 (US→USA, JP→JPN, FR→FRA …)
        return FootprintAtlas.shared.worldRegions
            .first { $0.code.hasPrefix(alpha2) }?.code ?? "KOR"
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
                    initialFocus: homeFocus,
                    focusCommand: focusCommand
                )
                .frame(height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color(hex: "#E8E2D6"), lineWidth: 1)
                )

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
