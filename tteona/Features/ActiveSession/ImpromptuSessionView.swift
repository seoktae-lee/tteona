import SwiftUI
import GoogleMaps
import CoreLocation
import AVFoundation

struct ImpromptuSessionView: View {
    var selectedRoomIds: Set<String> = []
    var onRestartWithRoomSelect: (() -> Void)? = nil
    /// 촬영 탭에서 '브이로그 만들기'로 들어온 경우 — 지도를 보여주되 바로 마무리 시트를 띄운다
    var startInFinishMode = false

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var roomService: RoomService
    @StateObject private var locationService = LocationService()
    @ObservedObject private var tutorial = VlogTutorial.shared
    @Environment(\.dismiss) private var dismiss

    private let activityManager = TodaySessionActivityManager.shared

    @State private var capturedPlaces: [Place] = []
    @State private var recordedSeconds: Double = 0   // 세션 누적 촬영 길이(초) — 진행률 바용
    @State private var cameraCommand: GMSCameraPosition?
    @State private var didCenterOnUser = false
    @State private var isResolvingLocation = false
    @State private var isSavingClip = false
    @State private var resolvedLocation: CLLocation? = nil
    @State private var pendingPlace: Place? = nil
    @State private var locationTask: Task<Void, Never>? = nil
    /// 전체화면도 하나로 — .fullScreenCover를 여러 개 붙이면 SwiftUI가 하나만 살린다.
    /// 카메라와 브이로그를 따로 달았더니 브이로그 쪽이 조용히 버려졌다.
    enum FullCover: Identifiable, Equatable {
        case camera, vlog
        var id: Int { self == .camera ? 0 : 1 }
    }
    @State private var fullCover: FullCover?
    @State private var pendingShowVlog = false
    @State private var pendingShowSaveCourse = false
    @State private var courseName = ""
    @State private var selectedTag: CourseTag = .friends
    @State private var generatedCourse: Course? = nil
    @State private var courseSavedToFirestore = false
    /// SwiftUI는 한 뷰에 .sheet(isPresented:)를 여러 개 붙이면 하나만 처리하고 나머지를 버린다.
    /// 예전엔 이어하기·장소·코스저장·마무리가 각각 .sheet로 달려 있어 마지막(마무리)이
    /// 영영 뜨지 않았다. 하나의 .sheet(item:)으로 합쳐 그 문제를 없앤다.
    enum ActiveSheet: Identifiable, Equatable {
        case resume, placePicker, saveCourse, end
        var id: Int {
            switch self {
            case .resume: return 0
            case .placePicker: return 1
            case .saveCourse: return 2
            case .end: return 3
            }
        }
    }
    @State private var activeSheet: ActiveSheet?
    /// 직전에 떠 있던 시트 — onDismiss에서 무엇이 닫혔는지 판별하는 데만 쓴다
    @State private var lastSheet: ActiveSheet?
    /// 직전에 떠 있던 전체화면 — onDismiss에서 무엇이 닫혔는지 판별용
    @State private var lastCover: FullCover?
    @State private var savedSession: SavedImpromptuSession? = nil
    @State private var activeRoomIds: Set<String> = []
    @State private var didStartSession = false
    @State private var cameraResult = false
    /// 촬영 시작 때 미리 정해두는 클립 파일명 — 장소는 촬영이 끝난 뒤에 붙는다
    @State private var pendingClipFileName: String? = nil
    @State private var showIntegrityAlert = false
    /// 오늘 기록 버리기 확인 — 되돌릴 수 없어 한 번 더 묻는다

    private let sessionStore = ImpromptuSessionStore.shared

    // 저장 경로는 게이팅 신원(currentUser)이 아니라 저장 신원을 쓴다 —
    // 인증 대기 같은 과도기에 경로가 바뀌면 찍어둔 클립을 잃는다
    private var uid: String { authService.identityUid }
    private var sessionId: String { "free_\(uid)" }
    private var nickname: String { userService.currentUser?.nickname ?? L("session.member") }

    var body: some View {
        ZStack {
            // 마무리 모드는 시트만 띄우면 된다. 지도·상단바·하단패널은 쓰지 않는데도
            // 그리면 구글 지도 초기화가 메인 스레드를 붙잡아 시트 예약이 실행되지 못한다.
            if startInFinishMode {
                // 투명하게 둔다 — 아래 촬영 화면이 그대로 보이고, 마무리 시트만
                // 카메라 위로 올라온 것처럼 읽힌다. 검은 판을 깔면 화면이 한 번
                // 통째로 바뀌었다가 시트가 뜨는 것으로 보여 흐름이 끊긴다.
                // (시트 자체의 딤 처리는 시스템이 해 준다)
                Color.clear.ignoresSafeArea()
            } else {
                mapLayer
                topBar
                bottomPanel
            }
            if isSavingClip {
                savingOverlay
            }
        }
        .ignoresSafeArea()
        .task {
            guard !didStartSession else { return }
            didStartSession = true
            // 튜토리얼: '나의 오늘' 진입 확인 → 촬영 유도 단계로
            tutorial.advance(to: .captureHere)
            locationService.requestPermission()
            locationService.startContinuousUpdates()
            activityManager.start()
            activeRoomIds = selectedRoomIds
            // 로그인 유저는 uid가 채워질 때까지 잠깐 기다린다(최대 3초).
            // 게스트는 uid가 끝내 없으므로 기다리면 3초를 그냥 버린다 — 건너뛴다.
            if authService.isLoggedIn {
                var waited = 0
                while uid.isEmpty && waited < 30 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
            }

            // 촬영 탭에서 '마치기'로 들어온 경우 — 진행 중인 세션을 들고 온 것이므로
            // "이어할까요?"는 묻지 않고 바로 복원한 뒤 마무리 시트로 간다.
            //
            // 시트는 반드시 fullScreenCover 전환이 끝난 뒤에 켠다. 등장과 동시에 켜면
            // (init 초깃값 포함) SwiftUI가 그 요청을 삼킨다 — 이어하기 시트가 예전에
            // 떴던 것도 .task 안에서 늦게 켜졌기 때문이다.
            if startInFinishMode {
                if let saved = sessionStore.loadTodaySession() { resumeSession(saved) }
                return   // 시트는 아래 onAppear가 띄운다 (.task는 취소될 수 있다)
            }

            // 이전 세션 복원 여부 확인
            if let saved = sessionStore.loadTodaySession(), !saved.places.isEmpty {
                savedSession = saved
                activeSheet = .resume
            } else {
                sessionStore.clear()
                startNewSession()
            }
        }
        // 마무리 시트는 .task가 아니라 여기서 띄운다.
        // .task는 뷰가 잠깐이라도 재구성되면 취소돼 대기 이후 코드가 실행되지 않는다
        // (실제로 로그가 'task 진입'에서 끊겼다). asyncAfter는 그 영향을 받지 않는다.
        .onAppear {
            guard startInFinishMode, activeSheet == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                activeSheet = .end
            }
        }
        .onDisappear {
            locationService.stopContinuousUpdates()
            activityManager.end()
            locationTask?.cancel()
        }
        .onChange(of: locationService.currentLocation) { _, loc in
            // 위치 첫 확보 시 내 위치로 카메라 이동 (이후엔 유저가 자유롭게 이동)
            guard let loc, !didCenterOnUser else { return }
            didCenterOnUser = true
            cameraCommand = GMSCameraPosition(latitude: loc.coordinate.latitude,
                                              longitude: loc.coordinate.longitude, zoom: 15)
        }
        .fullScreenCover(item: $fullCover, onDismiss: handleCoverDismiss) { cover in
            switch cover {
            case .camera:
                if let fileName = pendingClipFileName {
                    CameraView(
                        clipURL: clipURL(for: fileName),
                        sessionId: sessionId,
                        onSaved: { cameraResult = true },
                        onClose: { cameraResult = false }
                    )
                }
            case .vlog:
                if let course = generatedCourse {
                    VlogGenerationView(
                        course: course,
                        sessionId: sessionId,
                        thumbnailCourseId: courseSavedToFirestore ? course.courseId : nil,
                        shareRoomIds: activeRoomIds,
                        // 브이로그를 손에 넣은 그 순간 오늘 세션은 만료한다.
                        // 예전엔 이 정리를 '나가기' 버튼에 매달아 뒀는데, 그러면 다른 경로로
                        // 화면을 벗어났을 때 세션이 살아남아 촬영 탭 칩이 그대로 남았다.
                        onVlogCompleted: { sessionStore.clear() }
                    ) {
                        dismiss()
                    }
                }
            }
        }
        // 시트는 반드시 하나로 — .sheet를 여러 개 붙이면 SwiftUI가 하나만 살리고 나머지를 버린다
        .onChange(of: activeSheet) { _, new in
            if let new { lastSheet = new }
        }
        .onChange(of: fullCover) { _, new in
            if let new { lastCover = new }
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            switch sheet {
            case .resume:
                resumeSheet
            case .placePicker:
                placePickerSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.hidden)
            case .saveCourse:
                saveCourseSheet
            case .end:
                endSheet
            }
        }
        .alert(L("session.integrity.title"), isPresented: $showIntegrityAlert) {
            Button(L("common.ok"), role: .cancel) { }
        } message: {
            Text(L("session.integrity.message"))
        }
    }

    // MARK: - 저장 중 오버레이
    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.3)
                    .tint(.white)
                Text(L("impromptu.archiving"))
                    .font(.tte(15, .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.7))
            )
        }
        .transition(.opacity)
    }

    // MARK: - Map
    private var mapLayer: some View {
        GoogleMapView(
            markers: capturedPlaces.map { GoogleMapMarker(id: $0.id, coordinate: $0.coordinate, badgeNumber: $0.order) },
            polyline: capturedPlaces.count >= 2 ? capturedPlaces.map(\.coordinate) : nil,
            dashedPolyline: true,
            showsUserLocation: true,   // 내 위치는 구글맵 기본 파란 점
            initialCamera: locationService.currentLocation.map {
                GMSCameraPosition(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, zoom: 15)
            },
            cameraCommand: $cameraCommand
        )
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack {
            HStack {
                Button {
                    tutorial.handleSessionExit()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.tte(16, .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
                Spacer()
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text(L("impromptu.recording"))
                            .font(.tte(13, .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.6)))

                    // '나의 오늘'은 실시간 위치공유(지도 위 실시간 점)를 연결하지 않는다 —
                    // 그룹에는 시작/종료 활동만 공유하므로 "위치 공유 중" 배지는 표시하지 않는다.
                }
                Spacer()
                // 이어하기 결정 전에는 capturedPlaces가 아직 비어 있다 —
                // 그대로 두면 시트는 "3곳", 배지는 "0곳"으로 어긋나 보인다
                Text(L("main.placesCount",
                       activeSheet == .resume ? (savedSession?.places.count ?? 0) : capturedPlaces.count))
                    .font(.tte(14, .bold))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 40)
                    .background(Circle().fill(Color.tteOrange))
            }
            .padding(.horizontal, 20).padding(.top, 60)
            Spacer()
        }
    }

    // MARK: - Bottom Panel
    private var bottomPanel: some View {
        VStack {
            Spacer()

            // 튜토리얼 — 촬영/종료 버튼 바로 위에서 다음 행동을 안내
            if tutorial.isOn(.captureHere) {
                TutorialBubble(mascot: "tteoni-travel", text: L("tutorial.capture.text")) {
                    tutorial.finish()
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 6)
            } else if tutorial.isOn(.endToday) {
                TutorialBubble(mascot: "tteoni-wink", text: L("tutorial.endToday.text")) {
                    tutorial.finish()
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 6)
            }

            VStack(spacing: 12) {
                if !capturedPlaces.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(capturedPlaces) { place in
                                HStack(spacing: 4) {
                                    Text("\(place.order)")
                                        .font(.tte(11, .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(Color.tteOrange))
                                    Text(place.placeName)
                                        .font(.tte(13, .medium))
                                        .foregroundColor(.tteDarkGray)
                                        .lineLimit(1)
                                    Button {
                                        removePlace(place)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.tte(10, .bold))
                                            .foregroundColor(.tteMediumGray)
                                    }
                                }
                                .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 20)
                                    .fill(Color(UIColor.secondarySystemBackground)))
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                budgetBar
                HStack(spacing: 12) {
                    Button { startCapture() } label: {
                        HStack(spacing: 8) {
                            if isResolvingLocation {
                                ProgressView().tint(.white).scaleEffect(0.8)
                            } else {
                                Image(systemName: "camera.fill").font(.tte(16))
                            }
                            Text(budgetFull ? L("impromptu.budgetFull") : L("impromptu.captureHere"))
                                .font(.tte(16, .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(budgetFull ? Color.tteMediumGray : Color.tteOrange))
                    }
                    .disabled(isResolvingLocation || budgetFull)
                    .tutorialGlow(tutorial.isOn(.captureHere), cornerRadius: 14)

                    if !capturedPlaces.isEmpty {
                        Button { activeSheet = .end } label: {
                            Text(L("impromptu.endToday"))
                                .font(.tte(16, .semibold))
                                .foregroundColor(.tteOrange)
                                .frame(height: 54).frame(maxWidth: 110)
                                .background(RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.tteOrange, lineWidth: 1.5))
                        }
                        .tutorialGlow(tutorial.isOn(.endToday), cornerRadius: 14)
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.tteBackground)
                    .shadow(color: .black.opacity(0.1), radius: 16, y: -4)
            )
        }
    }

    // MARK: - 촬영 예산 진행률 바
    private var budgetSeconds: Double { ProManager.shared.vlogBudgetSeconds }
    private var budgetFull: Bool { recordedSeconds >= budgetSeconds }

    private var budgetBar: some View {
        let frac = min(1, max(0, recordedSeconds / budgetSeconds))
        return VStack(spacing: 6) {
            HStack {
                Text(L("impromptu.videoBudget"))
                    .font(.tte(12, .semibold))
                    .foregroundColor(.tteMediumGray)
                Spacer()
                Text(budgetValueText)
                    .font(.tte(12, .bold))
                    .foregroundColor(budgetFull ? .red : .tteOrange)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tteMediumGray.opacity(0.2))
                    Capsule()
                        .fill(budgetFull ? Color.red : Color.tteOrange)
                        .frame(width: max(0, geo.size.width * frac))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 4)
    }

    private var budgetValueText: String {
        if ProManager.shared.isPro {
            return "\(Self.mmss(recordedSeconds)) / \(Self.mmss(budgetSeconds))"
        }
        return L("impromptu.videoBudgetValue",
                 Int(recordedSeconds.rounded()), Int(budgetSeconds.rounded()))
    }

    private static func mmss(_ s: Double) -> String {
        let v = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", v / 60, v % 60)
    }

    /// 세션 폴더의 클립 길이를 합산해 진행률 바를 갱신한다.
    private func recomputeRecordedSeconds() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)")
        Task {
            var total: Double = 0
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension.lowercased() == "mp4" {
                if let d = try? await AVURLAsset(url: f).load(.duration) {
                    total += CMTimeGetSeconds(d)
                }
            }
            await MainActor.run { self.recordedSeconds = total }
        }
    }

    // MARK: - 오늘 종료 시트
    private var endSheet: some View {
        VStack(spacing: 0) {
            // 핸들
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 20)

            // 헤더
            VStack(spacing: 6) {
                Text(L("impromptu.endSheet.title"))
                    .font(.tte(20, .bold))
                    .foregroundColor(.tteDarkGray)
                Text(L("impromptu.endSheet.subtitle", capturedPlaces.count))
                    .font(.tte(14))
                    .foregroundColor(.tteMediumGray)

                // 튜토리얼 — '브이로그만 생성하기' 카드로 시선 유도
                if tutorial.isOn(.chooseVlogOnly) {
                    HStack(spacing: 6) {
                        Image("tteoni-wink")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                        Text(L("tutorial.vlogOnly.hint"))
                            .font(.tte(12.5, .bold))
                            .foregroundColor(.tteOrange)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.tteOrange.opacity(0.12)))
                    .padding(.top, 6)
                }
            }
            .padding(.bottom, 28)

            VStack(spacing: 12) {
                // 두 가지 마무리 방식 — 정사각형 카드 좌우 배치로 한눈에 비교
                HStack(spacing: 12) {
                    endChoiceCard(
                        icon: "film.fill",
                        title: L("impromptu.vlogOnly.title"),
                        subtitle: L("impromptu.vlogOnly.subtitle"),
                        isPrimary: true
                    ) {
                        tutorial.advance(to: .chooseFormat)
                        buildCourseAndEnd(saveToFirestore: false)
                        pendingShowVlog = true
                        activeSheet = nil
                    }
                    .tutorialGlow(tutorial.isOn(.chooseVlogOnly), cornerRadius: 20)

                    endChoiceCard(
                        icon: "mappin.and.ellipse",
                        title: L("impromptu.saveCourse.title"),
                        subtitle: L("impromptu.saveCourse.subtitle"),
                        isPrimary: false
                    ) {
                        pendingShowSaveCourse = true
                        activeSheet = nil
                    }
                }

                // 구분선
                HStack {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                    Text(L("common.or"))
                        .font(.tte(12))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                }
                .padding(.vertical, 2)

                // 계속 기록
                Button {
                    // 마침 모드였다면 handleSheetDismiss가 이어서 화면째 닫는다
                    activeSheet = nil
                } label: {
                    Text(L("impromptu.keepRecording"))
                        .font(.tte(15, .medium))
                        .foregroundColor(.tteOrange)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.tteOrange.opacity(0.4), lineWidth: 1))
                }

                // '오늘 기록 버리기'는 촬영 탭의 '오늘 찍은 곳' 시트로 옮겼다.
                // 지우는 일은 한 곳에 모으는 게 찾기 쉽고, '오늘을 마칠까요?'라는
                // 만드는 화면에서 '계속 기록할게요' 바로 아래에 파괴적인 버튼을 두면
                // 오조작 위험도 크다. (탈출구 자체는 그쪽에 그대로 살아 있다)
            }
            .padding(.horizontal, 20)

            Spacer().frame(height: 36)
        }
        .onAppear { tutorial.advance(to: .chooseVlogOnly) }
        .presentationDetents([.height(tutorial.isOn(.chooseVlogOnly) ? 426 : 390)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
    }

    // MARK: - 종료 선택 카드 (좌우 정사각형 배치)
    private func endChoiceCard(icon: String, title: String, subtitle: String,
                               isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle()
                        .fill(isPrimary ? Color.white.opacity(0.22) : Color.tteOrange.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.tte(18))
                        .foregroundColor(isPrimary ? .white : .tteOrange)
                }

                Spacer(minLength: 10)

                Text(title)
                    .font(.tte(16, .bold))
                    .foregroundColor(isPrimary ? .white : .tteDarkGray)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.tte(11.5))
                    .foregroundColor(isPrimary ? .white.opacity(0.85) : .tteMediumGray)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(isPrimary ? Color.tteOrange : Color(UIColor.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isPrimary ? Color.clear : Color.tteOrange.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 코스 저장 시트
    private var saveCourseSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("impromptu.courseName"))
                        .font(.tte(14, .medium)).foregroundColor(.tteMediumGray)
                    TextField(L("impromptu.courseName.placeholder"), text: $courseName)
                        .font(.tte(17)).padding(14)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color(UIColor.secondarySystemBackground)))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("impromptu.tag"))
                        .font(.tte(14, .medium)).foregroundColor(.tteMediumGray)
                    HStack(spacing: 10) {
                        ForEach(CourseTag.allCases, id: \.self) { tag in
                            Button { selectedTag = tag } label: {
                                Text(tag.displayName)
                                    .font(.tte(14, .medium))
                                    .foregroundColor(selectedTag == tag ? .white : .tteDarkGray)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Capsule().fill(
                                        selectedTag == tag ? Color.tteOrange
                                        : Color(UIColor.secondarySystemBackground)))
                            }
                        }
                    }
                }
                Spacer()
                Button {
                    tutorial.advance(to: .chooseFormat)
                    buildCourseAndEnd(saveToFirestore: true)
                    activeSheet = nil
                    fullCover = .vlog
                } label: {
                    Text(L("impromptu.saveAndVlog"))
                        .font(.tte(17, .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(courseName.trimmingCharacters(in: .whitespaces).isEmpty
                                  ? Color.gray.opacity(0.4) : Color.tteOrange))
                }
                .disabled(courseName.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.bottom, 36)
            }
            .padding(.horizontal, 20).padding(.top, 16)
            .navigationTitle(L("impromptu.saveAsCourse"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { activeSheet = nil }.foregroundColor(.tteDarkGray)
                }
            }
        }
    }

    // MARK: - Capture Flow

    /// 촬영을 먼저 연다. GPS·장소 확정을 앞에 두면 유저가 아무것도 못 하고 기다리게 된다.
    /// 클립 경로는 파일명으로 미리 고정하고, 장소는 촬영이 끝난 뒤 붙인다.
    private func startCapture() {
        guard pendingClipFileName == nil else { return }
        pendingPlace = nil
        pendingClipFileName = "\(UUID().uuidString).mp4"
        fullCover = .camera

        // 찍는 동안 백그라운드로 위치를 확보해 둔다 — 촬영이 끝났을 땐 이미 준비돼 있게
        locationTask?.cancel()
        resolvedLocation = nil
        isResolvingLocation = true
        locationTask = Task {
            defer { isResolvingLocation = false }
            resolvedLocation = try? await locationService.requestOneTimeLocation()
        }
    }

    /// 세션 폴더 안의 클립 경로 (VlogService.clipURL과 같은 규약)
    private func clipURL(for fileName: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tteona/Sessions/\(sessionId)/\(fileName)")
    }

    /// 장소가 붙지 않은 클립은 브이로그 합성에서 영영 안 쓰이므로 파일째 지운다
    private func discardPendingClip() {
        if let fileName = pendingClipFileName {
            try? FileManager.default.removeItem(at: clipURL(for: fileName))
        }
        pendingClipFileName = nil
        pendingPlace = nil
        locationTask?.cancel()
    }

    /// 촬영 후 장소 선택 시트 — 위치가 아직이면 기다리고, 실패하면 다시 시도하게 한다
    @ViewBuilder
    private var placePickerSheet: some View {
        if let loc = resolvedLocation {
            PlacePickerView(location: loc) { name in
                pendingPlace = Place(
                    order: capturedPlaces.count + 1,
                    placeName: name,
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    clipFileName: pendingClipFileName
                )
                activeSheet = nil
            }
        } else {
            VStack(spacing: 16) {
                if isResolvingLocation {
                    ProgressView()
                    Text(L("impromptu.locating"))
                        .font(.tte(14))
                        .foregroundColor(.tteMediumGray)
                } else {
                    Image(systemName: "location.slash")
                        .font(.tte(32))
                        .foregroundColor(.tteMediumGray)
                    Text(L("impromptu.locationFailed"))
                        .font(.tte(14))
                        .foregroundColor(.tteMediumGray)
                        .multilineTextAlignment(.center)
                    Button(L("common.retry")) {
                        locationTask?.cancel()
                        isResolvingLocation = true
                        locationTask = Task {
                            defer { isResolvingLocation = false }
                            resolvedLocation = try? await locationService.requestOneTimeLocation()
                        }
                    }
                    .font(.tte(15, .semibold))
                    .foregroundColor(.tteOrange)
                }
            }
            .padding(32)
        }
    }

    private func handleCameraSaved() {
        guard let place = pendingPlace else { return }
        Haptics.success()
        capturedPlaces.append(place)
        // 튜토리얼: 첫 장소 칩 확인 → '오늘 종료' 유도 단계로
        if capturedPlaces.count == 1 {
            tutorial.advance(to: .endToday)
        }
        reorderPlaces()
        recomputeRecordedSeconds()
        sessionStore.save(places: capturedPlaces, roomIds: Array(activeRoomIds))
        activityManager.update(placesCount: capturedPlaces.count, lastPlaceName: place.placeName)
        // 장소별 활동은 그룹 피드(앱 내 타임라인)에만 남긴다. 장소를 여러 곳 들를 때
        // 매번 푸시가 울리면 알림 폭탄이 되므로, '나의 오늘'은 시작/종료 푸시만 보낸다.
        // (freeCapture 피드는 채팅방 노출에서 이미 제외되어 있다 — chatVisibleFeedTypes)
        for rid in activeRoomIds {
            roomService.postFeed(roomId: rid, type: .freeCapture,
                                 userId: uid, nickname: nickname,
                                 courseId: "free", courseName: L("impromptu.myToday.name"),
                                 placeName: place.placeName,
                                 latitude: place.latitude,
                                 longitude: place.longitude)
        }
        pendingPlace = nil
        pendingClipFileName = nil
    }

    private func removePlace(_ place: Place) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        locationTask?.cancel()
        locationTask = nil
        isResolvingLocation = false
        pendingPlace = nil
        resolvedLocation = nil
        deleteClip(for: place)
        capturedPlaces.removeAll { $0.order == place.order }
        reorderPlaces()
        recomputeRecordedSeconds()
        if capturedPlaces.isEmpty {
            sessionStore.clear()
            // 튜토리얼: 칩이 다 사라지면 촬영 유도 단계로 복귀
            tutorial.regress(to: .captureHere)
        } else {
            sessionStore.save(places: capturedPlaces)
        }
        activityManager.update(
            placesCount: capturedPlaces.count,
            lastPlaceName: capturedPlaces.last?.placeName ?? L("impromptu.startRecord")
        )
    }

    private func reorderPlaces() {
        for i in capturedPlaces.indices {
            capturedPlaces[i] = Place(
                order: i + 1,
                placeName: capturedPlaces[i].placeName,
                latitude: capturedPlaces[i].latitude,
                longitude: capturedPlaces[i].longitude,
                clipFileName: capturedPlaces[i].clipFileName
            )
        }
    }

    private func deleteClip(for place: Place) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = place.clipFileName ?? {
            let safeName = place.placeName
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            return "\(place.order)_\(safeName).mp4"
        }()
        let url = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)/\(name)")
        try? FileManager.default.removeItem(at: url)
    }

    private func buildCourseAndEnd(saveToFirestore: Bool) {
        let name = courseName.trimmingCharacters(in: .whitespaces).isEmpty
            ? L("impromptu.myTodayDated", Date().formatted(.dateTime.month().day().locale(LanguageManager.shared.locale)))
            : courseName
        // Firestore에 저장되는 값이므로 표시용 번역문이 아닌 표준 한글명을 쓴다.
        // (번역은 읽는 쪽에서 Course.localizedRegion이 담당)
        let region = capturedPlaces.first.map {
            "\(String(format: "%.1f", $0.latitude))°N"
        } ?? "기타"
        let course = Course(
            courseId: UUID().uuidString, authorId: uid,
            courseName: name, tag: selectedTag, region: region,
            likeCount: 0, createdAt: Date(), places: capturedPlaces
        )
        generatedCourse = course
        courseSavedToFirestore = saveToFirestore
        // ⚠️ 여기서 세션을 지우면 안 된다. 브이로그 화면이 뜨지 못하면 기록만 사라지고
        //    유저는 되돌아갈 방법이 없다(실제로 그렇게 하루치가 날아갔다).
        //    정리는 브이로그를 실제로 받은 뒤에 한다.
        if saveToFirestore { Task { try? await courseService.saveCourse(course) } }
        postEndFeed(toRoomIds: Array(activeRoomIds), count: capturedPlaces.count)
    }

    private func postEndFeed(toRoomIds roomIds: [String], count: Int) {
        guard !roomIds.isEmpty else { return }
        FCMService.shared.requestGroupNotification(
            type: .freeTripEnd,
            senderUserId: uid,
            senderNickname: nickname,
            roomIds: roomIds,
            courseName: L("impromptu.placesVisited", count)
        )
        for rid in roomIds {
            roomService.postFeed(roomId: rid, type: .freeTripEnd,
                                 userId: uid, nickname: nickname,
                                 courseId: "free",
                                 courseName: L("impromptu.placesVisited", count))
        }
    }

    /// 어떤 커버가 닫혔는지에 따른 후처리. .fullScreenCover(item:)의 onDismiss도 닫힌 대상을
    /// 알려주지 않으므로 직전에 떠 있던 값(lastCover)을 보고 분기한다.
    private func handleCoverDismiss() {
        let closed = lastCover
        lastCover = nil
        if closed == .camera {
            if cameraResult {
                cameraResult = false
                activeSheet = .placePicker     // 찍었으니 이제 장소를 고른다
            } else {
                discardPendingClip()           // 촬영을 취소했다
            }
        }

        // 브이로그 화면은 '완성 후 나가기'일 때만 스스로 여기까지 닫는다.
        // 포맷 선택의 '닫기'나 실패 화면의 '돌아가기'로 물러나면 커버만 사라져,
        // 마침 모드의 빈 화면이 그대로 드러난다 — 시트와 같은 규칙으로 화면째 닫는다.
        dismissIfFinishModeIsEmpty()
    }

    /// 마침 모드(촬영 탭 ✓로 열림)는 시트·커버를 얹으려고만 존재하는 화면이라 그 아래엔
    /// 지도도 UI도 없다. 위에 아무것도 남지 않으면 빈 화면에 갇히므로 화면째 물러난다.
    private func dismissIfFinishModeIsEmpty() {
        guard startInFinishMode, activeSheet == nil, fullCover == nil else { return }
        dismiss()
    }

    /// 어떤 시트가 닫혔는지에 따른 후처리. .sheet(item:)의 onDismiss는 닫힌 대상을
    /// 알려주지 않으므로 직전에 떠 있던 값(lastSheet)을 보고 분기한다.
    private func handleSheetDismiss() {
        switch lastSheet {
        case .placePicker:
            if pendingPlace != nil {
                handleCameraSaved()
            } else {
                // 장소를 정하지 않고 닫았다 — 고아 클립을 남기지 않는다
                discardPendingClip()
            }
        case .end:
            // 종료 시트에서 고른 다음 단계를 닫힘 완료 후 실행
            if pendingShowVlog {
                pendingShowVlog = false
                fullCover = .vlog
            } else if pendingShowSaveCourse {
                pendingShowSaveCourse = false
                activeSheet = .saveCourse
            }
        default:
            break
        }

        // 다음 단계로 이어지지 않은 채 시트가 닫혔다면 빈 화면이 드러난다.
        // '계속 기록' 버튼이든, 시트를 쓸어내렸든, 코스 저장을 취소했든 경로를 가리지 않는다.
        dismissIfFinishModeIsEmpty()
        lastSheet = nil
    }

    private func startNewSession() {
        // 세션 폴더(free_{uid})는 유저당 고정이라 이전 세션 클립이 남아 있으면
        // 촬영 예산(무료 30초)을 그대로 소진시킨다 — 새 세션은 깨끗한 폴더로 시작
        deleteAllClips()
        capturedPlaces = []
        recordedSeconds = 0
        activeRoomIds = selectedRoomIds
        let roomIds = Array(activeRoomIds)
        dlog("[Feed] startNewSession uid=\(uid) nickname=\(nickname) roomIds=\(roomIds)")
        for rid in roomIds {
            roomService.postFeed(roomId: rid, type: .freeTripStart,
                                 userId: uid, nickname: nickname,
                                 courseId: "free", courseName: L("impromptu.myToday.name"))
        }
    }

    private func resumeSession(_ session: SavedImpromptuSession) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // 세션 폴더 자체가 없으면 '파일이 사라진 것'이 아니라 엉뚱한 곳을 보고 있을
        // 가능성이 크다(신원이 아직 안 정해졌거나 경로가 어긋난 상황). 그 상태에서
        // 목록을 정리하면 멀쩡한 하루치 기록을 지운다 — 손대지 않고 그대로 이어간다.
        let sessionDir = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)")
        guard FileManager.default.fileExists(atPath: sessionDir.path) else {
            capturedPlaces = session.places
            reorderPlaces()
            recomputeRecordedSeconds()
            if !capturedPlaces.isEmpty { tutorial.advance(to: .endToday) }
            if !session.roomIds.isEmpty { activeRoomIds = Set(session.roomIds) }
            return
        }

        let validatedPlaces = session.places.filter { place in
            let name: String
            if let clipFileName = place.clipFileName {
                name = clipFileName
            } else {
                let safeName = place.placeName.replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_")
                name = "\(place.order)_\(safeName).mp4"
            }
            let url = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)/\(name)")
            return FileManager.default.fileExists(atPath: url.path)
        }

        if validatedPlaces.count < session.places.count {
            showIntegrityAlert = true
        }

        capturedPlaces = validatedPlaces
        reorderPlaces()
        recomputeRecordedSeconds()

        // 튜토리얼: 이전 세션에 이미 칩이 있으면 촬영 단계는 건너뛴다
        if !capturedPlaces.isEmpty {
            tutorial.advance(to: .endToday)
        }

        if !session.roomIds.isEmpty {
            activeRoomIds = Set(session.roomIds)
        }
    }

    private func deleteAllClips() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 이어서 / 새로 시작 시트
    private var resumeSheet: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 24)

            // 아이콘
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
                Text(L("impromptu.savedSession.title"))
                    .font(.tte(20, .bold))
                    .foregroundColor(.tteDarkGray)
                if let saved = savedSession {
                    Text(L("impromptu.savedSession.detail", saved.places.count, Self.timeString(saved.date)))
                        .font(.tte(14))
                        .foregroundColor(.tteMediumGray)
                }
            }
            .padding(.bottom, 32)

            VStack(spacing: 12) {
                // 이어서 기록하기
                Button {
                    if let saved = savedSession { resumeSession(saved) }
                    activeSheet = nil
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.tte(15))
                        Text(L("main.continueRecording"))
                            .font(.tte(16, .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }

                // 새로 시작하기
                Button {
                    deleteAllClips()
                    sessionStore.clear()
                    activeSheet = nil
                    if let restart = onRestartWithRoomSelect {
                        // 부모가 이 화면을 닫고 onDismiss에서 방 선택을 다시 연다
                        restart()
                    } else {
                        startNewSession()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.tte(15))
                        Text(L("main.startFresh"))
                            .font(.tte(16, .medium))
                    }
                    .foregroundColor(.tteDarkGray)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 16)
                        .fill(Color(UIColor.secondarySystemBackground)))
                }
            }
            .padding(.horizontal, 24)

            Spacer().frame(height: 40)
        }
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .interactiveDismissDisabled(true)
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = LanguageManager.shared.locale
        f.setLocalizedDateFormatFromTemplate("a h:mm")
        return f.string(from: date)
    }
}

// MARK: - Free Session Pin
struct FreeSessionPin: View {
    let order: Int
    var body: some View {
        ZStack {
            Circle().fill(Color.tteOrange).frame(width: 32, height: 32)
                .shadow(color: .tteOrange.opacity(0.4), radius: 4)
            Text("\(order)").font(.tte(13, .bold)).foregroundColor(.white)
        }
    }
}
