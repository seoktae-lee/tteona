import SwiftUI
import CoreLocation

/// 앱을 열면 가장 먼저 보이는 촬영 탭.
///
/// 뷰파인더가 상주하고 셔터를 누르면 바로 찍힌다 — 장소·GPS·그룹 선택은 전부 촬영 뒤로 밀었다.
/// 셔터·촬영 예산·권한 안내는 CameraView(UIKit)가 이미 갖고 있으므로 그대로 임베드하고,
/// 이 뷰는 그 위에 세션 상태 칩과 촬영 후 장소 선택만 얹는다.
struct CaptureTabView: View {
    /// 촬영 중에는 탭바를 숨긴다 (MainTabView가 관찰)
    @Binding var isRecording: Bool

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @ObservedObject private var sessionStore = ImpromptuSessionStore.shared
    @ObservedObject private var pro = ProManager.shared
    /// 세션 누적 촬영 시간(초) — 카메라가 세션 폴더에서 계산해 올려준다
    @State private var usedSeconds: Double = 0
    @StateObject private var locationService = LocationService()

    @State private var places: [Place] = []
    /// 촬영 시작 전에 정해두는 클립 파일명 — 장소는 촬영이 끝난 뒤 붙는다
    @State private var clipFileName = UUID().uuidString + ".mp4"
    @State private var showPlacePicker = false
    /// 전체화면 표시도 하나로 — .fullScreenCover를 여러 개 붙이면 SwiftUI가 하나만 살린다.
    /// (페이월과 마무리를 따로 달았더니 마무리 커버가 떴다가 곧바로 철회돼 .task가 취소됐다)
    enum FullCover: Identifiable, Equatable {
        case paywall, finish
        var id: Int { self == .paywall ? 0 : 1 }
    }
    @State private var fullCover: FullCover?
    @State private var resolvedLocation: CLLocation?
    @State private var isResolvingLocation = false
    @State private var locationTask: Task<Void, Never>?
    /// 방금 기록된 장소 안내 — 칩 숫자만 바뀌면 찍혔는지 확신이 안 선다
    @State private var savedToast: String?
    @State private var toastTask: Task<Void, Never>?
    @AppStorage("camera.showGrid") private var showGrid = false
    /// 노출 보정(EV) — 역광에서 얼굴이 어둡게 나오는 걸 직접 잡는다
    @State private var exposureBias: Float = 0
    /// Slider는 Double만 받는다 — 카메라로는 Float으로 넘어간다
    @State private var exposureBiasD: Double = 0
    /// 줌 UI 배율 (1x 기준, 슬라이더로 연속 조절)
    @State private var zoomUI: Double = 1
    /// UIKit 카메라가 알려준 하단 UI 실측 좌표 — 기기별 겹침을 막는 유일한 기준
    @State private var layoutMetrics = CameraLayoutMetrics()

    private var uid: String { authService.currentUser?.uid ?? "" }
    private var sessionId: String { "free_\(uid)" }
    private var clipURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tteona/Sessions/\(sessionId)/\(clipFileName)")
    }

    var body: some View {
        ZStack(alignment: .top) {
            CameraView(
                clipURL: clipURL,
                sessionId: sessionId,
                isEmbedded: true,
                onRecordingChanged: { recording in
                    withAnimation(.easeInOut(duration: 0.2)) { isRecording = recording }
                    // 찍는 동안 위치를 확보해 둔다 — 촬영이 끝났을 땐 이미 준비돼 있게
                    if recording { requestLocation() }
                },
                onUsedSecondsChanged: { seconds in
                    DispatchQueue.main.async { usedSeconds = seconds }
                },
                exposureBias: exposureBias,
                zoomUI: zoomUI,
                // 핀치로 줌하면 슬라이더도 같이 움직인다
                onZoomUIChanged: { zoomUI = min(max($0, 1), 5) },
                onLayoutMetricsChanged: { layoutMetrics = $0 },
                onSaved: { showPlacePicker = true }
            )
            .ignoresSafeArea()

            if showGrid { gridOverlay }   // 촬영 중에도 유지 — 구도 보조가 목적이다

            // 줌·밝기·격자는 촬영 중에도 조작할 수 있어야 한다. 숨기는 건 탭바뿐.
            cameraControls

            VStack(spacing: 8) {
                if !places.isEmpty && !isRecording {
                    sessionChip
                        .transition(.opacity)
                }
                if let toast = savedToast, !isRecording {
                    savedToastView(toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 8)
        }
        // 오늘 마치기 — 우측 상단. 셔터에서 멀리 떨어뜨려 오조작을 막는다
        .overlay(alignment: .topTrailing) {
            if !places.isEmpty && !isRecording {
                Button {
                    Haptics.light()
                    fullCover = .finish
                } label: {
                    Image(systemName: "checkmark")
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.tteOrange))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                }
                .padding(.trailing, 16)
                .padding(.top, 8)
                .accessibilityLabel(L("capture.finish"))
                .transition(.opacity)
            }
        }
        .onChange(of: exposureBiasD) { _, v in exposureBias = Float(v) }
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: savedToast)
        .onAppear {
            // 세션이 다른 화면에서 비워졌을 수 있다(새로하기·브이로그 완성) — 진입할 때마다 맞춘다
            places = sessionStore.loadTodaySession()?.places ?? []
            if places.isEmpty {
                // 기록은 없는데 클립 파일만 남으면 예산이 찬 채로 촬영도 삭제도 못 하게 갇힌다.
                // 세션이 비어 있으면 남은 파일도 함께 정리해 그 상태를 원천 차단한다.
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Tteona/Sessions/\(sessionId)")
                try? FileManager.default.removeItem(at: dir)
                usedSeconds = 0
            }
            // 위치 권한을 여기서 요청하면 카메라 권한 팝업과 앱 실행 직후 겹쳐 뜬다.
            // 위치는 실제로 촬영을 시작할 때(onRecordingChanged) 요청한다.
        }
        .onDisappear { isRecording = false }
        .sheet(isPresented: $showPlacePicker, onDismiss: {
            // 장소를 정하지 않고 닫으면 고아 클립이 남는다 — 파일째 지운다
            if places.count == (sessionStore.loadTodaySession()?.places.count ?? 0) {
                try? FileManager.default.removeItem(at: clipURL)
                clipFileName = UUID().uuidString + ".mp4"
            }
        }) {
            placePickerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
        }
        .fullScreenCover(item: $fullCover, onDismiss: {
            // 마무리에서 브이로그까지 갔으면 세션이 비워져 있다
            places = sessionStore.loadTodaySession()?.places ?? []
        }) { cover in
            switch cover {
            case .paywall:
                ProPaywallView()
            case .finish:
                ImpromptuSessionView(startInFinishMode: true)
                    .environmentObject(AppNotificationManager.shared)
                    .environmentObject(authService)
                    .environmentObject(userService)
                    .environmentObject(roomService)
            }
        }
    }

    // MARK: - 세션 상태 칩 (탭하면 마무리)

    private var budgetSeconds: Double { pro.vlogBudgetSeconds }
    private var budgetRatio: Double {
        guard budgetSeconds > 0 else { return 0 }
        return min(1, usedSeconds / budgetSeconds)
    }
    private var budgetFull: Bool { budgetRatio >= 1 }
    /// 남은 촬영 예산(초) — 이보다 긴 길이를 골라도 이만큼만 찍힌다
    private var remainingSeconds: Double { max(0, budgetSeconds - usedSeconds) }

    /// 셔터 아래 안내 — 실제로 찍히게 될 시간을 말한다
    private var captureHint: String {
        guard let picked = pro.effectiveClipLength.seconds else { return L("camera.hint") }
        if remainingSeconds < 1 { return L("impromptu.budgetFull") }
        return L("camera.hintAuto", Int(min(picked, remainingSeconds).rounded()))
    }

    private var sessionChip: some View {
        Button {
            Haptics.light()
            fullCover = .finish
        } label: {
            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(budgetFull ? Color.white.opacity(0.5) : Color.red)
                        .frame(width: 7, height: 7)
                    Text(L("capture.progress", places.count,
                           Int(usedSeconds.rounded()), Int(budgetSeconds.rounded())))
                        .font(.tte(13, .bold))
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.tte(10, .semibold))
                        .opacity(0.7)
                }
                // 남은 촬영 예산 — 장소 수는 상한이 없어 바로 표현할 수 없지만 예산은 가능하다
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule()
                            .fill(budgetFull ? Color.white : Color.tteOrange)
                            .frame(width: max(4, geo.size.width * budgetRatio))
                    }
                }
                .frame(height: 4)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(width: 210)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.6)))
        }
        .accessibilityLabel(L("capture.finish"))
        .animation(.easeOut(duration: 0.35), value: budgetRatio)
    }

    // MARK: - 촬영 보조 컨트롤
    //
    // 셔터·줌바는 UIKit(CameraView)이 화면 아래쪽을 쓴다. 좌표를 상수로 박으면 SE와
    // Pro Max에서 반드시 어긋나므로, UIKit이 레이아웃할 때 알려준 실측값(layoutMetrics)을
    // 기준으로 자리를 잡는다. 아직 값이 안 왔으면(첫 프레임) 컨트롤을 그리지 않는다.
    @ViewBuilder
    private var cameraControls: some View {
        if layoutMetrics.shutterCenterFromBottom > 0 {
            ZStack(alignment: .bottom) {
                // 클립 길이 — 셔터 위
                VStack(spacing: 8) {
                    clipLengthChips
                    // 하단 안내는 SwiftUI가 그린다. UIKit 레이블로 그리면 문구가 바뀔 때마다
                    // 레이아웃 → 좌표 변경 → SwiftUI 갱신 → 다시 문구 갱신으로 루프가 돈다.
                    Text(captureHint)
                        .font(.tte(13))
                        .foregroundColor(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.4), radius: 3)
                }
                .padding(.bottom, layoutMetrics.contentTopFromBottom)
                .frame(maxHeight: .infinity, alignment: .bottom)

                // 좌: 줌 · 우: 밝기 — 칩보다 위쪽 영역을 세로로 쓴다
                HStack {
                    verticalSlider(value: $zoomUI, range: 1...5,
                                   icon: "plus.magnifyingglass",
                                   isDefault: zoomUI == 1) { zoomUI = 1 }
                    Spacer()
                    verticalSlider(value: $exposureBiasD, range: -2...2,
                                   icon: "sun.max.fill",
                                   isDefault: exposureBias == 0) { exposureBiasD = 0 }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, layoutMetrics.contentTopFromBottom + 52)

                // 격자 — 셔터와 같은 높이 좌측 (전환 버튼과 좌우 대칭)
                HStack {
                    Button {
                        Haptics.light()
                        showGrid.toggle()
                    } label: {
                        Image(systemName: "grid")
                            .font(.tte(16, .semibold))
                            .foregroundColor(showGrid ? .tteOrange : .white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .accessibilityLabel(L("camera.grid"))
                    Spacer()
                }
                .padding(.leading, 24)
                .padding(.bottom, layoutMetrics.shutterCenterFromBottom - 22)
            }
            // UIKit이 알려준 값은 '화면 맨 아래' 기준이다. 세이프에어리어 안에 놓으면
            // 탭바·홈인디케이터 높이만큼 통째로 밀려 올라가 셔터·칩이 겹친다.
            .ignoresSafeArea()
        }
    }

    /// 클립 길이 — 총 예산을 어떻게 쪼갤지의 선택. 10초·무제한은 PRO
    /// 지금 화면에 낼 길이들. 무료 유저에게 잠긴 길이를 셋씩 늘어놓을 이유가 없다 —
    /// 어느 걸 눌러도 같은 페이월로 가므로 '더 길게' 하나로 묶는다.
    /// 칩 개수가 줄어 작은 기기에서도 안전하고, 자물쇠가 하나뿐이라 덜 인색해 보인다.
    private var visibleLengths: [VlogClipLength] {
        pro.isPro ? VlogClipLength.allCases : VlogClipLength.allCases.filter { !$0.requiresPro }
    }

    private var clipLengthChips: some View {
        HStack(spacing: 6) {
            ForEach(visibleLengths) { length in
                let selected = pro.effectiveClipLength == length
                // 남은 예산보다 긴 길이는 골라도 잘려서 찍힌다 — 미리 흐리게 알린다
                let overBudget = (length.seconds ?? .infinity) > remainingSeconds
                Button {
                    Haptics.light()
                    pro.clipLength = length
                } label: {
                    Text(length.shortLabel)
                        .font(.tte(13, .bold))
                        .foregroundColor(selected ? .black : .white.opacity(overBudget ? 0.45 : 1))
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(Capsule().fill(selected ? Color.white : Color.black.opacity(0.45)))
                }
            }

            if !pro.isPro {
                // 잠긴 길이를 만지는 순간이 가장 자연스러운 업셀 지점이다
                Button {
                    Haptics.light()
                    fullCover = .paywall
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill").font(.tte(9))
                        Text(L("camera.clipLength.more"))
                            .font(.tte(13, .bold))
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                }
            }
        }
    }

    /// 세로 슬라이더 공용 — 회전한 Slider는 레이아웃 크기가 회전 전 기준이라
    /// 바깥 frame으로 실제 차지할 영역을 못박아야 다른 컨트롤과 겹치지 않는다.
    private func verticalSlider(value: Binding<Double>, range: ClosedRange<Double>,
                                icon: String, isDefault: Bool,
                                reset: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: reset) {
                Image(systemName: icon)
                    .font(.tte(13, .semibold))
                    .foregroundColor(isDefault ? .white.opacity(0.85) : .tteOrange)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            Slider(value: value, in: range)
                .tint(.tteOrange)
                .frame(width: 150)
                .rotationEffect(.degrees(-90))
                .frame(width: 40, height: 150)
                // 최솟값일 때는 주황 트랙이 없어 손잡이만 떠 보인다 — 배경으로 축을 그려준다
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: 30)
                )
        }
    }

    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    let y = geo.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 기록 완료 토스트 — 2초 뒤 스스로 사라진다 (닫을 필요 없음)
    private func savedToastView(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.tte(13, .semibold))
                .foregroundColor(.tteOrange)
            Text(text)
                .font(.tte(13, .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .padding(.horizontal, 24)
    }

    // MARK: - 촬영 후 장소 선택

    @ViewBuilder
    private var placePickerSheet: some View {
        if let loc = resolvedLocation {
            PlacePickerView(location: loc) { name in
                appendPlace(name: name, location: loc)
                showPlacePicker = false
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
                    Button(L("common.retry")) { requestLocation() }
                        .font(.tte(15, .semibold))
                        .foregroundColor(.tteOrange)
                }
            }
            .padding(32)
        }
    }

    // MARK: - Actions

    private func showSavedToast(placeName: String, index: Int) {
        savedToast = L("capture.saved", placeName, index)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            savedToast = nil
        }
    }

    private func requestLocation() {
        guard !isResolvingLocation else { return }
        locationService.requestPermission()
        locationTask?.cancel()
        isResolvingLocation = true
        locationTask = Task {
            defer { isResolvingLocation = false }
            resolvedLocation = try? await locationService.requestOneTimeLocation()
        }
    }

    private func appendPlace(name: String, location: CLLocation) {
        let place = Place(
            order: places.count + 1,
            placeName: name,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            clipFileName: clipFileName
        )
        places.append(place)
        sessionStore.save(places: places)
        Haptics.success()
        showSavedToast(placeName: name, index: places.count)
        // 다음 촬영을 위해 새 파일명을 예약한다
        clipFileName = UUID().uuidString + ".mp4"
    }
}
