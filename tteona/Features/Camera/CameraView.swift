import SwiftUI
import AVFoundation
import UIKit

struct CameraView: View {
    /// 클립이 저장될 경로 — 촬영 시점에 장소가 없어도 되도록 URL을 직접 받는다
    let clipURL: URL
    let sessionId: String
    /// 상단에 표시할 장소명. 아직 정해지지 않았으면(나의 오늘) nil — 레이블을 숨긴다
    var title: String? = nil
    var onSaved: () -> Void = {}
    var onClose: (() -> Void)? = nil
    /// 탭에 상주시킬 때 true — 닫기 버튼을 감추고 저장 후 스스로 닫지 않는다
    var isEmbedded = false
    /// 바깥에서 클립을 지웠을 때 예산 재계산을 요청하는 신호
    var budgetRefreshToken: Int = 0
    var onRecordingChanged: ((Bool) -> Void)? = nil
    var onUsedSecondsChanged: ((Double) -> Void)? = nil
    /// 노출 보정(EV) — 촬영 탭의 슬라이더가 값을 내려보낸다
    var exposureBias: Float = 0
    /// 줌 UI 배율 — 좌측 세로 슬라이더가 값을 내려보낸다
    var zoomUI: Double = 1
    /// 핀치로 줌이 바뀌면 슬라이더를 맞추기 위해 올려보낸다
    var onZoomUIChanged: ((Double) -> Void)? = nil
    /// UIKit이 잡은 하단 UI 좌표 — SwiftUI 오버레이가 겹치지 않게 자리를 잡는 데 쓴다
    var onLayoutMetricsChanged: ((CameraLayoutMetrics) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    /// 장소가 이미 확정된 세션(코스 따라가기)용 편의 생성자
    init(place: Place, sessionId: String,
         onSaved: @escaping () -> Void = {}, onClose: (() -> Void)? = nil) {
        self.clipURL = VlogService.clipURL(place: place, sessionId: sessionId)
        self.sessionId = sessionId
        self.title = place.placeName
        self.onSaved = onSaved
        self.onClose = onClose
    }

    init(clipURL: URL, sessionId: String, title: String? = nil,
         budgetRefreshToken: Int = 0,
         isEmbedded: Bool = false,
         onRecordingChanged: ((Bool) -> Void)? = nil,
         onUsedSecondsChanged: ((Double) -> Void)? = nil,
         exposureBias: Float = 0,
         zoomUI: Double = 1,
         onZoomUIChanged: ((Double) -> Void)? = nil,
         onLayoutMetricsChanged: ((CameraLayoutMetrics) -> Void)? = nil,
         onSaved: @escaping () -> Void = {}, onClose: (() -> Void)? = nil) {
        self.clipURL = clipURL
        self.sessionId = sessionId
        self.title = title
        self.budgetRefreshToken = budgetRefreshToken
        self.isEmbedded = isEmbedded
        self.onRecordingChanged = onRecordingChanged
        self.onUsedSecondsChanged = onUsedSecondsChanged
        self.exposureBias = exposureBias
        self.zoomUI = zoomUI
        self.onZoomUIChanged = onZoomUIChanged
        self.onLayoutMetricsChanged = onLayoutMetricsChanged
        self.onSaved = onSaved
        self.onClose = onClose
    }

    var body: some View {
        CameraViewControllerWrapper(
            clipURL: clipURL, sessionId: sessionId,
            budgetRefreshToken: budgetRefreshToken, title: title,
            isEmbedded: isEmbedded, onRecordingChanged: onRecordingChanged,
            onUsedSecondsChanged: onUsedSecondsChanged,
            exposureBias: exposureBias, zoomUI: zoomUI,
            onZoomUIChanged: onZoomUIChanged,
            onLayoutMetricsChanged: onLayoutMetricsChanged
        ) {
            onSaved()
        } onClose: {
            onClose?()
            if !isEmbedded { dismiss() }
        }
        .ignoresSafeArea()
    }
}

struct CameraViewControllerWrapper: UIViewControllerRepresentable {
    let clipURL: URL
    let sessionId: String
    /// 바깥에서 클립을 지웠을 때 예산 재계산을 요청하는 신호
    var budgetRefreshToken: Int = 0
    let title: String?
    var isEmbedded = false
    var onRecordingChanged: ((Bool) -> Void)? = nil
    var onUsedSecondsChanged: ((Double) -> Void)? = nil
    var exposureBias: Float = 0
    var zoomUI: Double = 1
    var onZoomUIChanged: ((Double) -> Void)? = nil
    var onLayoutMetricsChanged: ((CameraLayoutMetrics) -> Void)? = nil
    let onSaved: () -> Void
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController(clipURL: clipURL, sessionId: sessionId, placeTitle: title)
        vc.isEmbedded = isEmbedded
        vc.onSaved = onSaved
        vc.onClose = onClose
        vc.onRecordingChanged = onRecordingChanged
        vc.onUsedSecondsChanged = onUsedSecondsChanged
        vc.onLayoutMetricsChanged = onLayoutMetricsChanged
        vc.onZoomUIChanged = onZoomUIChanged
        return vc
    }

    func updateUIViewController(_ vc: CameraViewController, context: Context) {
        // 임베드 모드에서는 촬영마다 저장 경로가 바뀐다 — 뷰를 새로 만들지 않고 갈아끼운다
        vc.clipURL = clipURL
        vc.sessionId = sessionId   // 신원이 늦게 정해지면 세션 폴더도 따라 바뀐다
        vc.budgetRefreshToken = budgetRefreshToken
        vc.applyExposureBias(exposureBias)
        vc.applyZoomUI(zoomUI)
        vc.onSaved = onSaved
        vc.onClose = onClose
        vc.onRecordingChanged = onRecordingChanged
        vc.onUsedSecondsChanged = onUsedSecondsChanged
        vc.onLayoutMetricsChanged = onLayoutMetricsChanged
        vc.onZoomUIChanged = onZoomUIChanged
    }
}

/// UIKit 카메라가 실제로 잡은 하단 UI 위치. SwiftUI 오버레이가 이 값을 기준으로 자리를 잡아
/// 기기 크기·세이프에어리어가 달라도 셔터·줌바와 겹치지 않게 한다.
/// (좌표를 상수로 박아두면 SE와 Pro Max에서 반드시 어긋난다.)
struct CameraLayoutMetrics: Equatable {
    /// 셔터 중심의 화면 하단으로부터의 거리
    var shutterCenterFromBottom: CGFloat = 0
    /// 이 높이 위로는 UIKit이 아무것도 그리지 않는다 — SwiftUI가 써도 되는 경계
    var contentTopFromBottom: CGFloat = 0
}

// MARK: - CameraViewController
final class CameraViewController: UIViewController {
    /// 하단 UI 좌표가 바뀔 때만 알린다 (레이아웃 → 상태 변경 → 재레이아웃 루프 방지)
    var onLayoutMetricsChanged: ((CameraLayoutMetrics) -> Void)?
    private var lastMetrics = CameraLayoutMetrics()
    var onSaved: (() -> Void)?
    var onClose: (() -> Void)?
    /// 녹화 시작/종료 알림 — 촬영 중에는 탭바를 숨기는 데 쓴다
    var onRecordingChanged: ((Bool) -> Void)?
    /// 세션 누적 촬영 시간(초) — 촬영 탭의 예산 진행 바에 쓴다
    var onUsedSecondsChanged: ((Double) -> Void)?
    /// 핀치로 바뀐 줌 배율 — 좌측 슬라이더를 따라오게 한다
    var onZoomUIChanged: ((Double) -> Void)?

    /// 탭에 상주하는 모드. 스스로 닫지 않고, 저장 후 다음 촬영을 받을 준비만 한다.
    var isEmbedded = false
    /// 다음 클립 경로 — 임베드 모드에서는 촬영마다 부모가 갈아끼운다
    /// 이번 촬영이 저장될 경로. 임베드 모드에서는 촬영마다 새 파일명으로 갈아끼워진다.
    ///
    /// 경로가 바뀌면 재촬영 환불분을 반드시 비운다. 환불은 **같은 파일을 덮어쓸 때만**
    /// 유효한데, 촬영 탭은 매번 새 파일명을 쓰므로 직전 클립 길이가 그대로 남아 있으면
    /// 다음 촬영에서 예산을 부당하게 돌려받는다 — 30초를 넘겨도 계속 찍히던 원인이다.
    var clipURL: URL {
        didSet {
            guard clipURL != oldValue else { return }
            currentPlaceClipSeconds = 0
        }
    }
    /// 세션 폴더 이름. **let이 아니다** — 앱 실행 직후엔 신원(uid)이 아직 없어 `free_`로
    /// 만들어졌다가, 게스트 로그인이 끝나면 `free_{uid}`로 바뀐다. 여기서 갱신하지 않으면
    /// 저장 경로(clipURL)만 옮겨가고 촬영 예산 계산은 계속 빈 폴더를 세서 0초에 머문다.
    var sessionId: String {
        didSet {
            guard sessionId != oldValue else { return }
            refreshUsedSeconds()
        }
    }

    /// 바깥에서 클립을 지웠을 때 예산을 다시 세게 하는 신호.
    /// 값이 바뀌면 폴더를 다시 훑는다 — 지운 만큼 예산이 즉시 돌아온다.
    var budgetRefreshToken: Int = 0 {
        didSet {
            guard budgetRefreshToken != oldValue else { return }
            refreshUsedSeconds()
        }
    }
    /// UIViewController.title과 이름이 겹치지 않게 placeTitle로 둔다
    private let placeTitle: String?
    private let service = CameraService()

    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let recordBtn = UIButton(type: .custom)
    private let outerRing = CAShapeLayer()
    private let innerDot = CAShapeLayer()
    private let clipProgress = CAShapeLayer()   // 녹화 버튼 링 = 이번 클립(장소당) 진행
    private let clipHint = UILabel()        // 버튼 아래: "이번 장소 · 최대 5초"
    private let hintLabel = UILabel()
    private let zoomBar = UIStackView()
    private var progressTimer: Timer?
    private var recordStart: Date?
    private var currentClipLimit: Double = 5   // 이번 클립 상한(초) — 버튼 링 진행률 계산용
    private var zoomBaseFactor: Double = 1      // 핀치 시작 시점의 줌 배율
    // 세션 총 촬영 예산 — 무료 30초(장소당 5초) / PRO 5분(장소당 제한 없음). 기존 클립 합계 + 현재 클립으로 계산
    private var usedSeconds: Double = 0
    // 이 장소에 이미 저장된 클립 길이 — 재촬영 시 덮어써지므로 예산에서 돌려받는다
    private var currentPlaceClipSeconds: Double = 0
    private var budgetSeconds: Double { ProManager.shared.vlogBudgetSeconds }
    private var tipChip: UIView?
    private var savingOverlay: UIView?
    private var permissionOverlay: UIView?

    // 무료(5초 고정 자동 촬영)와 PRO(탭으로 종료)는 안내 문구가 다르다
    private var isAutoClip: Bool { ProManager.shared.vlogClipMaxSeconds != nil }
    /// 선택한 클립 길이를 문구에 반영한다 (칩을 바꾸면 아래 안내도 같이 바뀌어야 한다)
    /// 실제로 찍히게 될 시간 — 남은 예산이 선택한 길이보다 짧으면 그만큼만 찍힌다.
    /// 문구가 "5초"라고 해놓고 2초만 찍히면 유저는 고장으로 받아들인다.
    private var clipSecondsInt: Int {
        guard let picked = ProManager.shared.vlogClipMaxSeconds else { return 0 }
        let effective = Int(min(picked, max(0, budgetSeconds - usedSeconds)).rounded())
        return effective > 0 ? effective : Int(picked.rounded())
    }
    private var idleHint: String {
        isAutoClip ? L("camera.hintAuto", clipSecondsInt) : L("camera.hint")
    }
    private var recordingHint: String { isAutoClip ? L("camera.recordingHintAuto") : L("camera.recordingHint") }

    init(clipURL: URL, sessionId: String, placeTitle: String?) {
        self.clipURL = clipURL
        self.sessionId = sessionId
        self.placeTitle = placeTitle
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 노출 보정 적용 — 같은 값이 반복 전달되면(SwiftUI 재평가) 건너뛴다
    private var appliedExposureBias: Float = .nan
    private var appliedZoomUI: Double = .nan
    func applyZoomUI(_ f: Double) {
        guard f != appliedZoomUI else { return }
        appliedZoomUI = f
        service.setContinuousZoomUI(f)
    }

    func applyExposureBias(_ ev: Float) {
        guard ev != appliedExposureBias else { return }
        appliedExposureBias = ev
        service.setExposureBias(ev)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        checkAndStartCamera()
        refreshUsedSeconds()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        progressTimer?.invalidate()
        progressTimer = nil
        service.stopSession()
        if service.isRecording {
            service.cancelRecording()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        layoutBottomUI()
        layoutTipChip()
        // 전환 버튼 위치는 layoutBottomUI가 셔터 기준으로 잡는다
    }

    /// 탭에 상주하면 viewDidLoad가 한 번만 돌기 때문에, 다른 탭에 갔다 오면
    /// viewDidDisappear에서 멈춘 세션이 그대로 멈춰 있어 화면이 얼어붙는다.
    /// 돌아올 때마다 다시 켠다 (아직 구성 전이면 그때 구성한다).
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if service.didConfigure {
            service.resumeSession()
        } else {
            checkAndStartCamera()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        layoutBottomUI()
        layoutTipChip()
        // 3초 후 fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            UIView.animate(withDuration: 0.5) {
                self?.tipChip?.alpha = 0
            } completion: { _ in
                self?.tipChip?.isHidden = true
            }
        }
    }

    // MARK: - Build UI
    private func buildUI() {
        previewLayer.session = service.captureSession
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        // 닫기 버튼
        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeBtn.tintColor = .white
        closeBtn.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeBtn.layer.cornerRadius = 22
        closeBtn.frame = CGRect(x: 20, y: 60, width: 44, height: 44)
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        // 탭에 상주할 때는 닫을 대상이 없다 — 탭바로 나가면 된다
        closeBtn.isHidden = isEmbedded
        view.addSubview(closeBtn)

        // 장소명 레이블 — '나의 오늘'은 촬영 후에 장소를 정하므로 그때는 표시하지 않는다
        let placeL = UILabel()
        placeL.text = placeTitle ?? ""
        placeL.isHidden = (placeTitle?.isEmpty ?? true)
        placeL.textColor = .white
        placeL.font = .systemFont(ofSize: 15, weight: .semibold)
        placeL.textAlignment = .center
        placeL.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        placeL.layer.cornerRadius = 16
        placeL.clipsToBounds = true
        placeL.sizeToFit()
        placeL.frame = CGRect(x: 0, y: 0, width: placeL.frame.width + 28, height: 36)
        placeL.center = CGPoint(x: view.bounds.midX, y: 82)
        view.addSubview(placeL)

        // 힌트
        hintLabel.text = idleHint
        hintLabel.isHidden = isEmbedded
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textAlignment = .center
        hintLabel.sizeToFit()
        view.addSubview(hintLabel)

        // 전면/후면 전환 버튼
        let flipBtn = UIButton(type: .system)
        flipBtn.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera.fill"), for: .normal)
        flipBtn.tintColor = .white
        flipBtn.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        flipBtn.layer.cornerRadius = 22
        flipBtn.frame = CGRect(x: view.bounds.width - 64, y: 60, width: 44, height: 44)
        flipBtn.tag = 902
        flipBtn.addTarget(self, action: #selector(flipTapped), for: .touchUpInside)
        view.addSubview(flipBtn)

        // 줌 바
        zoomBar.axis = .horizontal
        zoomBar.spacing = 8
        view.addSubview(zoomBar)
        for (title, factor) in [("0.5x", 0.5), ("1x", 1.0), ("3x", 3.0)] as [(String, Double)] {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            b.tintColor = .white
            b.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            b.layer.cornerRadius = 22
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 44),
                b.heightAnchor.constraint(equalToConstant: 44)
            ])
            b.tag = Int(factor * 10)
            b.addTarget(self, action: #selector(zoomTapped(_:)), for: .touchUpInside)
            zoomBar.addArrangedSubview(b)
        }
        setZoomSelected(1.0)
        // 촬영 탭은 좌측 세로 슬라이더로 줌하므로 프리셋 바를 쓰지 않는다.
        // (flipCamera 쪽에서도 같은 조건으로 다시 잡아준다)
        zoomBar.isHidden = isEmbedded

        buildRecordButton()
        buildTipChip()
        buildSavingOverlay()
        buildPermissionOverlay()
        setupGestures()
    }

    // MARK: - 핀치 줌 / 탭 초점 제스처
    private func setupGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        // 초광각(0.5x)은 렌즈 전환이라 zoomBar 버튼으로 처리하고, 핀치는 1x 이상 연속 줌만 담당
        if service.currentCameraPosition == .front { return }
        switch g.state {
        case .began:
            zoomBaseFactor = max(1, service.currentZoomFactor)
        case .changed, .ended:
            service.setContinuousZoom(zoomBaseFactor * Double(g.scale))
            setZoomSelected(-1)   // 커스텀 줌 중에는 프리셋 강조 해제
            // 슬라이더가 핀치를 따라오게 현재 배율을 올려보낸다.
            // appliedZoomUI를 먼저 맞춰 두지 않으면 그 값이 다시 내려와 줌을 덮어써 떨린다.
            let ui = service.currentZoomUI
            appliedZoomUI = ui
            onZoomUIChanged?(ui)
        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: view)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: p)
        service.focus(at: devicePoint)
        showFocusIndicator(at: p)
    }

    private func showFocusIndicator(at point: CGPoint) {
        let box = UIView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        box.center = point
        box.layer.borderColor = UIColor(red: 1, green: 0.42, blue: 0.21, alpha: 1).cgColor
        box.layer.borderWidth = 1.5
        box.layer.cornerRadius = 6
        box.isUserInteractionEnabled = false
        box.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        view.addSubview(box)
        UIView.animate(withDuration: 0.25, animations: {
            box.transform = .identity
        }) { _ in
            UIView.animate(withDuration: 0.35, delay: 0.6, options: []) {
                box.alpha = 0
            } completion: { _ in
                box.removeFromSuperview()
            }
        }
    }

    private func buildPermissionOverlay() {
        let overlay = UIView(frame: view.bounds)
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        overlay.isHidden = true
        overlay.alpha = 0
        view.addSubview(overlay)
        permissionOverlay = overlay

        let title = UILabel()
        title.text = L("camera.permission.title")
        title.textColor = .white
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = UILabel()
        subtitle.text = L("camera.permission.subtitle")
        subtitle.textColor = UIColor.white.withAlphaComponent(0.75)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let settingsBtn = UIButton(type: .system)
        settingsBtn.setTitle(L("camera.openSettings"), for: .normal)
        settingsBtn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        settingsBtn.tintColor = .white
        settingsBtn.backgroundColor = UIColor(red: 1, green: 0.42, blue: 0.21, alpha: 1)
        settingsBtn.layer.cornerRadius = 14
        settingsBtn.translatesAutoresizingMaskIntoConstraints = false
        settingsBtn.addTarget(self, action: #selector(openSettingsTapped), for: .touchUpInside)

        let closeBtn = UIButton(type: .system)
        closeBtn.setTitle(L("common.close"), for: .normal)
        closeBtn.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        closeBtn.tintColor = UIColor.white.withAlphaComponent(0.8)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, subtitle, settingsBtn, closeBtn])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),

            settingsBtn.heightAnchor.constraint(equalToConstant: 54),
        ])
    }

    /// 권한 요청이 떠 있는 동안 viewWillAppear가 한 번 더 부르면 requestAccess가 중첩돼
    /// 콜백이 돌아오지 않고 앱이 멈춘다. 진행 중일 때는 다시 들어가지 않는다.
    private var isStartingCamera = false

    private func checkAndStartCamera() {
        guard !isStartingCamera else { return }
        isStartingCamera = true
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)

        func startIfPossible() {
            service.configure()
            service.onRecordingFinished = { [weak self] url in
                DispatchQueue.main.async { self?.recordingDone(url: url) }
            }
            // 실제 첫 프레임이 도착하면 클립 타이머 기준시각을 그때로 맞춘다 (첫 촬영 짧게 잘림 방지)
            service.onRecordingStarted = { [weak self] in
                guard let self, self.recordStart == nil, self.service.isRecording else { return }
                self.recordStart = Date()
                // 링을 첫 프레임 시점부터 상한(currentClipLimit)까지 선형으로 채운다.
                // 녹화 종료도 같은 첫 프레임 기준 sample-time으로 상한에 도달하므로
                // 링은 항상 한 바퀴를 꽉 채운 뒤 종료된다.
                self.startClipRingAnimation(duration: self.currentClipLimit)
            }
        }

        switch videoStatus {
        case .authorized:
            startIfPossible()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        startIfPossible()
                    } else {
                        self?.isStartingCamera = false   // 설정에서 허용 후 재진입 시 다시 시도
                        self?.showPermissionOverlay()
                    }
                }
            }
        case .denied, .restricted:
            isStartingCamera = false
            showPermissionOverlay()
        @unknown default:
            isStartingCamera = false
            showPermissionOverlay()
        }
    }

    private func showPermissionOverlay() {
        permissionOverlay?.isHidden = false
        UIView.animate(withDuration: 0.2) { [weak self] in
            self?.permissionOverlay?.alpha = 1
        }
    }

    @objc private func openSettingsTapped() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func buildSavingOverlay() {
        let overlay = UIView(frame: view.bounds)
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        overlay.isHidden = true
        view.addSubview(overlay)
        savingOverlay = overlay

        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        container.layer.cornerRadius = 18
        container.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(container)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let indicator = UIActivityIndicatorView(style: .large)
        indicator.color = .white
        indicator.startAnimating()
        indicator.tag = 701

        let checkMark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        checkMark.tintColor = .green
        checkMark.contentMode = .scaleAspectFit
        checkMark.isHidden = true
        checkMark.tag = 702
        NSLayoutConstraint.activate([
            checkMark.widthAnchor.constraint(equalToConstant: 48),
            checkMark.heightAnchor.constraint(equalToConstant: 48)
        ])

        // 실패 아이콘 — 저장이 결과물 없이 끝났을 때 (인코딩 실패·저장공간 부족 등)
        let failMark = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
        failMark.tintColor = UIColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)
        failMark.contentMode = .scaleAspectFit
        failMark.isHidden = true
        failMark.tag = 704
        NSLayoutConstraint.activate([
            failMark.widthAnchor.constraint(equalToConstant: 48),
            failMark.heightAnchor.constraint(equalToConstant: 48)
        ])

        let label = UILabel()
        label.text = L("camera.saving")
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.tag = 703

        // 보조 문구 — 실패했을 때만 보인다 ("다시 찍어주세요")
        let subLabel = UILabel()
        subLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subLabel.font = .systemFont(ofSize: 12)
        subLabel.textAlignment = .center
        subLabel.isHidden = true
        subLabel.tag = 705

        stack.addArrangedSubview(indicator)
        stack.addArrangedSubview(checkMark)
        stack.addArrangedSubview(failMark)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(subLabel)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            container.widthAnchor.constraint(equalToConstant: 200),
            container.heightAnchor.constraint(equalToConstant: 160),

            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }

    // MARK: - 촬영 예산 (무료 30초·장소당 5초 / PRO 5분)

    /// 세션 폴더의 기존 클립 길이를 합산해 남은 예산(사용량)을 갱신 — 예산 소진 판정용.
    /// 총량 UI는 카메라에서 제거(지도 장소칩에 있음)했으므로 화면 갱신은 하지 않는다.
    private func refreshUsedSeconds() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)")
        let currentClipURL = clipURL
        Task { [weak self] in
            guard let self else { return }
            var total: Double = 0
            var currentClip: Double = 0
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension.lowercased() == "mp4" {
                if let d = try? await AVURLAsset(url: f).load(.duration) {
                    let sec = CMTimeGetSeconds(d)
                    total += sec
                    if f.lastPathComponent == currentClipURL.lastPathComponent { currentClip = sec }
                }
            }
            self.usedSeconds = total
            self.currentPlaceClipSeconds = currentClip
            self.onUsedSecondsChanged?(total)
            self.updateShutterAvailability()
        }
    }

    /// 녹화 버튼 링 = 이번 클립 진행률. 첫 프레임 시점에 0→1 선형 애니메이션을 걸어
    /// 상한 시간에 정확히 한 바퀴가 차도록 한다. (타이머 갱신 방식은 벽시계 지연·암묵
    /// 애니메이션 랙으로 링이 중간에 멈춘 것처럼 보이는 문제가 있어 이 방식으로 대체.)
    private func startClipRingAnimation(duration: Double) {
        clipProgress.removeAnimation(forKey: "clipFill")
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = max(duration, 0.1)
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        clipProgress.strokeEnd = 1   // 모델값은 꽉 찬 상태로 고정, 표시는 애니메이션이 담당
        clipProgress.add(anim, forKey: "clipFill")
    }

    /// 링을 즉시 비우고 진행 애니메이션을 제거한다 (녹화 시작 전/종료 후 초기화용).
    private func resetClipRing() {
        clipProgress.removeAnimation(forKey: "clipFill")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipProgress.strokeEnd = 0
        CATransaction.commit()
    }

    /// 오늘 세션 폴더의 클립을 전부 지우고 기록도 비운다 — 예산이 0으로 돌아간다.
    /// 세션 기록이 이미 사라진 뒤에도(클립만 남은 상태) 여기서 빠져나올 수 있어야 한다.
    private func discardTodaySession() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)")
        try? FileManager.default.removeItem(at: dir)
        ImpromptuSessionStore.shared.clear()
        usedSeconds = 0
        currentPlaceClipSeconds = 0
        onUsedSecondsChanged?(0)
        presentedViewController?.dismiss(animated: true)
        refreshUsedSeconds()
    }

    private func showBudgetAlert() {
        let popup = VlogLimitPopupView(
            isPro: ProManager.shared.isPro,
            onUpgrade: { [weak self] in
                self?.presentedViewController?.dismiss(animated: true) {
                    let paywall = UIHostingController(rootView: ProPaywallView())
                    paywall.modalPresentationStyle = .fullScreen
                    self?.present(paywall, animated: true)
                }
            },
            onDismiss: { [weak self] in
                self?.presentedViewController?.dismiss(animated: true)
            },
            // 예산이 찼는데 브이로그를 못 만들면 갇힌다 — 여기서 오늘 기록을 버리고 빠져나온다
            onDiscardToday: { [weak self] in
                self?.discardTodaySession()
            }
        )
        let host = UIHostingController(rootView: popup)
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        present(host, animated: true)
    }

    private func buildRecordButton() {
        recordBtn.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        recordBtn.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        view.addSubview(recordBtn)

        let c = CGPoint(x: 40, y: 40)
        outerRing.path = UIBezierPath(arcCenter: c, radius: 38, startAngle: 0,
                                      endAngle: .pi*2, clockwise: true).cgPath
        outerRing.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        outerRing.fillColor = UIColor.clear.cgColor
        outerRing.lineWidth = 4
        recordBtn.layer.addSublayer(outerRing)

        // 이번 클립 진행 링 — 12시부터 시계방향으로 채워지며 상한(5초)에 닿으면 꽉 참
        clipProgress.path = UIBezierPath(arcCenter: c, radius: 38, startAngle: -.pi/2,
                                         endAngle: .pi*1.5, clockwise: true).cgPath
        clipProgress.strokeColor = UIColor.white.cgColor
        clipProgress.fillColor = UIColor.clear.cgColor
        clipProgress.lineWidth = 4
        clipProgress.lineCap = .round
        clipProgress.strokeEnd = 0
        recordBtn.layer.addSublayer(clipProgress)

        innerDot.path = UIBezierPath(arcCenter: c, radius: 30, startAngle: 0,
                                     endAngle: .pi*2, clockwise: true).cgPath
        innerDot.fillColor = UIColor.red.cgColor
        recordBtn.layer.addSublayer(innerDot)

        // 버튼 아래 힌트 — 이번 장소의 클립 상한
        // 촬영 탭에서는 길이 칩이 같은 정보를 보여준다 — 대기 중엔 비워 중복을 없앤다
        clipHint.text = isEmbedded ? ""
            : (ProManager.shared.vlogClipMaxSeconds == nil
               ? L("camera.clipHintPro") : L("camera.clipHintFree", clipSecondsInt))
        clipHint.textColor = UIColor.white.withAlphaComponent(0.9)
        clipHint.font = .systemFont(ofSize: 12, weight: .semibold)
        clipHint.textAlignment = .center
        view.addSubview(clipHint)
    }

    // MARK: - 촬영 팁 칩
    private func buildTipChip() {
        let chip = UIView()
        chip.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        chip.layer.cornerRadius = 16
        chip.isUserInteractionEnabled = false
        view.addSubview(chip)
        tipChip = chip

        // 촬영 예산 안내 — 3초 뒤 사라지는 토스트 (총량 UI는 상시 표시하지 않는다)
        let label = UILabel()
        label.text = isAutoClip
            ? L("camera.budgetToastFree", Int((ProManager.shared.vlogClipMaxSeconds ?? 5).rounded()),
                                          Int(ProManager.shared.vlogBudgetSeconds.rounded()))
            : L("camera.budgetToastPro", Int((ProManager.shared.vlogBudgetSeconds / 60).rounded()))
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        label.tag = 811
        chip.addSubview(label)
    }

    private func layoutTipChip() {
        guard let chip = tipChip,
              let label = chip.viewWithTag(811) as? UILabel else { return }
        label.sizeToFit()
        let chipW = label.frame.width + 32
        let chipH: CGFloat = 32
        chip.frame = CGRect(
            x: (view.bounds.width - chipW) / 2,
            y: 82 + 36 / 2 + 12,
            width: chipW, height: chipH
        )
        label.frame = chip.bounds
    }

    private func layoutBottomUI() {
        let w = view.bounds.width
        let safeBottom = view.safeAreaInsets.bottom > 0 ? view.safeAreaInsets.bottom : 34

        hintLabel.sizeToFit()
        hintLabel.frame.origin = CGPoint(
            x: (w - hintLabel.frame.width) / 2,
            y: view.bounds.height - safeBottom - hintLabel.frame.height - 8
        )
        let zoomW = CGFloat(zoomBar.arrangedSubviews.count) * 44
            + CGFloat(zoomBar.arrangedSubviews.count - 1) * 8
        zoomBar.frame = CGRect(
            x: (w - zoomW) / 2,
            y: hintLabel.frame.minY - 44 - 12,
            width: zoomW, height: 44
        )
        // 촬영 탭은 줌바를 쓰지 않는다 — 그만큼 셔터를 아래로 내려 화면을 넓게 쓴다
        let bottomAnchor = isEmbedded ? hintLabel.frame.minY : zoomBar.frame.minY
        // 버튼 바로 아래 클립 힌트
        clipHint.sizeToFit()
        clipHint.frame.origin = CGPoint(
            x: (w - clipHint.frame.width) / 2,
            y: bottomAnchor - clipHint.frame.height - 12
        )
        recordBtn.center = CGPoint(x: w / 2, y: clipHint.frame.minY - 12 - 40)
        // 전환 버튼 — 셔터와 같은 높이 우측. 상단은 '오늘 마치기'가 쓴다.
        // 셔터에서 충분히 떨어뜨려 촬영 중 오조작을 막는다.
        view.viewWithTag(902)?.center = CGPoint(x: w - 46, y: recordBtn.center.y)

        // SwiftUI 오버레이에 실제 좌표를 알려준다 — 값이 바뀔 때만
        let h = view.bounds.height
        let metrics = CameraLayoutMetrics(
            shutterCenterFromBottom: h - recordBtn.center.y,
            contentTopFromBottom: h - recordBtn.frame.minY + 16
        )
        if metrics != lastMetrics {
            lastMetrics = metrics
            DispatchQueue.main.async { [weak self] in
                self?.onLayoutMetricsChanged?(metrics)
            }
        }
    }

    // MARK: - Actions
    @objc private func closeTapped() { onClose?() }

    @objc private func flipTapped() {
        service.flipCamera()
        let isFront = service.currentCameraPosition == .front
        zoomBar.isHidden = isFront || isEmbedded
        if let flipBtn = view.viewWithTag(902) as? UIButton {
            UIView.animate(withDuration: 0.15, animations: {
                flipBtn.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            }) { _ in
                UIView.animate(withDuration: 0.15) { flipBtn.transform = .identity }
            }
        }
    }

    @objc private func recordTapped() {
        if service.isRecording {
            // 무료 유저는 5초 고정 촬영 — 중간 종료 불가 ("한 번 탭 = 한 칸(5초)" 멘탈모델).
            // 실수한 컷은 같은 장소에서 재촬영하면 예산을 돌려받으므로 부담 없다.
            guard ProManager.shared.vlogClipMaxSeconds == nil else { return }
            stopRecordingUI()
            return
        }
        // 재촬영이면 기존 클립이 덮어써지므로 그 길이만큼 예산을 돌려받는다
        if currentPlaceClipSeconds > 0 {
            usedSeconds = max(0, usedSeconds - currentPlaceClipSeconds)
            currentPlaceClipSeconds = 0
        }
        let remaining = budgetSeconds - usedSeconds
        guard remaining >= 1 else {
            showBudgetAlert()
            return
        }
        // 무료 유저는 한 장소(클립)당 5초 상한, PRO는 남은 예산 전체
        let clipLimit: Double
        if let clipMax = ProManager.shared.vlogClipMaxSeconds {
            clipLimit = min(clipMax, remaining)
        } else {
            clipLimit = remaining
        }
        service.maxDuration = clipLimit
        currentClipLimit = clipLimit
        resetClipRing()
        // recordStart는 '실제 첫 프레임' 콜백(onRecordingStarted)에서 설정된다 —
        // 링 채우기 애니메이션도 그 콜백에서 시작해 첫 프레임 시점에 정확히 맞춘다.
        // 카메라 워밍업 지연 동안 벽시계가 앞서 달려 첫 촬영이 짧게 잘리는 문제 방지.
        recordStart = nil
        service.startRecording(to: clipURL)
        setInnerDot(recording: true)
        hintLabel.text = recordingHint
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let s = self.recordStart else { return }
            let elapsed = Date().timeIntervalSince(s)
            // 링 채우기는 startClipRingAnimation의 CABasicAnimation이 담당한다.
            // 여기서는 버튼 아래 힌트 텍스트만 경과/상한으로 갱신 (예: "2.3 / 5초")
            self.clipHint.text = L("camera.clipElapsed",
                                   String(format: "%.1f", min(elapsed, clipLimit)),
                                   Int(clipLimit.rounded()))
            // 안전장치: 실제 종료는 CameraService가 sample-time maxDuration에서 담당한다.
            // 벽시계가 크게 초과할 때만 백업으로 종료(첫 프레임 지연을 고려해 여유 +1.5s).
            if elapsed >= clipLimit + 1.5 {
                self.stopRecordingUI()
            }
        }
    }

    /// 예산이 다 찼으면 셔터를 눌리지 않게 하고 흐리게 표시한다.
    /// 눌러도 알림만 뜨면 "왜 안 찍히지?"가 되므로, 버튼 자체가 상태를 말하게 한다.
    private func updateShutterAvailability() {
        let full = (budgetSeconds - usedSeconds) < 1
        recordBtn.isEnabled = !full
        recordBtn.alpha = full ? 0.35 : 1.0
    }

    private func stopRecordingUI() {
        progressTimer?.invalidate()
        progressTimer = nil
        savingOverlay?.isHidden = false
        view.isUserInteractionEnabled = false
        service.stopRecording()
    }

    @objc private func zoomTapped(_ sender: UIButton) {
        let f = Double(sender.tag) / 10.0
        service.setZoom(f)
        setZoomSelected(f)
    }

    private func recordingDone(url: URL?) {
        progressTimer?.invalidate()
        progressTimer = nil
        recordStart = nil

        // 방금 찍은 만큼을 **즉시** 차감한다.
        //
        // refreshUsedSeconds는 세션 폴더의 파일 길이를 비동기로 읽어 합산하는데, 그 사이에
        // 다음 촬영이 시작되면 낡은 usedSeconds로 남은 예산을 계산해 예산을 넘겨 찍는다.
        // (30초 예산에서 35초가 찍힌 원인 — 클립이 늘수록 재계산이 느려져 창이 넓어진다)
        // 모든 클립은 상한에서 자동 종료되므로 상한만큼 차감하면 실제와 일치하고,
        // 정확한 값은 뒤이은 재계산이 파일 기준으로 다시 맞춘다.
        if currentClipLimit > 0 {
            usedSeconds += currentClipLimit
            currentClipLimit = 0
            onUsedSecondsChanged?(usedSeconds)
            updateShutterAvailability()
        }
        refreshUsedSeconds()   // 파일 기준으로 재계산 (재촬영 덮어쓰기 반영)
        resetClipRing()
        // 촬영 탭에서는 길이 칩이 같은 정보를 보여준다 — 대기 중엔 비워 중복을 없앤다
        clipHint.text = isEmbedded ? ""
            : (ProManager.shared.vlogClipMaxSeconds == nil
               ? L("camera.clipHintPro") : L("camera.clipHintFree", clipSecondsInt))
        hintLabel.text = idleHint
        setInnerDot(recording: false)
        
        if url != nil {
            showSaveSuccessAndClose()
        } else {
            showSaveFailure()
        }
    }

    /*
     * 저장이 결과물 없이 끝났음을 알린다.
     *
     * 예전엔 오버레이만 조용히 걷었다. 화면이 촬영 직전과 똑같아져서 사용자는 찍힌 줄 알고
     * 다음 장소로 이동하고, 브이로그를 만들 때가 되어서야 그 장소가 비어 있는 걸 발견한다.
     * 실패도 결과이므로 그 자리에서 알린다. 다음 단계로는 넘기지 않는다.
     */
    private func showSaveFailure() {
        savingOverlay?.isHidden = false
        view.isUserInteractionEnabled = false
        savingOverlay?.viewWithTag(701)?.isHidden = true   // indicator
        savingOverlay?.viewWithTag(702)?.isHidden = true   // checkMark
        savingOverlay?.viewWithTag(704)?.isHidden = false  // failMark
        if let label = savingOverlay?.viewWithTag(703) as? UILabel {
            label.text = L("camera.saveFailed")
            label.font = .systemFont(ofSize: 15, weight: .medium)
        }
        if let sub = savingOverlay?.viewWithTag(705) as? UILabel {
            sub.text = L("camera.saveFailed.sub")
            sub.isHidden = false
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.savingOverlay?.isHidden = true
            self.view.isUserInteractionEnabled = true
            // 다음 촬영을 위해 오버레이를 원래 모습으로 되돌린다
            self.savingOverlay?.viewWithTag(701)?.isHidden = false
            self.savingOverlay?.viewWithTag(704)?.isHidden = true
            self.savingOverlay?.viewWithTag(705)?.isHidden = true
            if let label = self.savingOverlay?.viewWithTag(703) as? UILabel {
                label.text = L("camera.saving")
                label.font = .systemFont(ofSize: 16, weight: .medium)
            }
        }
    }

    private func showSaveSuccessAndClose() {
        // 무료(5초 자동 종료) 경로는 stopRecordingUI를 거치지 않아 오버레이가 아직 숨겨져 있다.
        // 여기서 직접 띄워야 두 경로 모두에서 저장 완료 문구가 보인다.
        savingOverlay?.isHidden = false
        view.isUserInteractionEnabled = false
        savingOverlay?.viewWithTag(701)?.isHidden = true  // indicator
        savingOverlay?.viewWithTag(702)?.isHidden = false // checkMark
        if let label = savingOverlay?.viewWithTag(703) as? UILabel {
            label.text = L("camera.saveSuccess")
        }
        // 성공 햅틱은 세션 화면의 onSaved 핸들러가 울린다 (여기서 울리면 두 번 진동)
        // 1.2초 대기 후 자동 닫기 (임베드 모드는 닫지 않고 다음 촬영을 받을 준비만 한다)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.onSaved?()
            if self.isEmbedded {
                self.savingOverlay?.isHidden = true
                self.view.isUserInteractionEnabled = true
                self.refreshUsedSeconds()
            } else {
                self.dismiss(animated: true)
            }
        }
    }

    private func setInnerDot(recording: Bool) {
        onRecordingChanged?(recording)
        let c = CGPoint(x: 40, y: 40)
        let to: CGPath = recording
            ? UIBezierPath(roundedRect: CGRect(x: 24, y: 24, width: 32, height: 32),
                           cornerRadius: 8).cgPath
            : UIBezierPath(arcCenter: c, radius: 30, startAngle: 0,
                           endAngle: .pi*2, clockwise: true).cgPath
        let a = CABasicAnimation(keyPath: "path")
        a.fromValue = innerDot.path; a.toValue = to; a.duration = 0.2
        innerDot.add(a, forKey: nil); innerDot.path = to
    }

    private func setZoomSelected(_ factor: Double) {
        for v in zoomBar.arrangedSubviews {
            guard let b = v as? UIButton else { continue }
            let selected = Double(b.tag) / 10.0 == factor
            b.backgroundColor = selected ? .white : UIColor.black.withAlphaComponent(0.45)
            b.tintColor = selected ? .black : .white
        }
    }
}

// MARK: - 제스처 델리게이트
extension CameraViewController: UIGestureRecognizerDelegate {
    // 닫기·전환·줌·녹화 버튼 위의 탭은 초점/줌 제스처가 가로채지 않게 한다
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        return !(touch.view is UIControl)
    }
}
