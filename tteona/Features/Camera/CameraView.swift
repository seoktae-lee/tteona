import SwiftUI
import AVFoundation
import MetalKit
import UIKit

struct CameraView: View {
    let place: Place
    let sessionId: String
    var onSaved: () -> Void = {}
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CameraViewControllerWrapper(place: place, sessionId: sessionId) {
            onSaved()
        } onClose: {
            onClose?()
            dismiss()
        }
        .ignoresSafeArea()
    }
}

struct CameraViewControllerWrapper: UIViewControllerRepresentable {
    let place: Place
    let sessionId: String
    let onSaved: () -> Void
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController(place: place, sessionId: sessionId)
        vc.onSaved = onSaved
        vc.onClose = onClose
        return vc
    }
    func updateUIViewController(_ vc: CameraViewController, context: Context) {}
}

// MARK: - CameraViewController
final class CameraViewController: UIViewController {
    var onSaved: (() -> Void)?
    var onClose: (() -> Void)?

    private let place: Place
    private let sessionId: String
    private let service = CameraService()

    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let recordBtn = UIButton(type: .custom)
    private let outerRing = CAShapeLayer()
    private let innerDot = CAShapeLayer()
    private let clipProgress = CAShapeLayer()   // 녹화 버튼 링 = 이번 클립(장소당) 진행
    private let clipHint = UILabel()        // 버튼 아래: "이번 장소 · 최대 5초"
    private let hintLabel = UILabel()
    private let zoomBar = UIStackView()
    private let filterBar = UIStackView()               // 나루 무드 필터 칩
    private var filteredPreview: FilteredPreviewMTKView? // 필터 선택 시에만 표시되는 Metal 프리뷰
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
    private var idleHint: String { isAutoClip ? L("camera.hintAuto") : L("camera.hint") }
    private var recordingHint: String { isAutoClip ? L("camera.recordingHintAuto") : L("camera.recordingHint") }

    init(place: Place, sessionId: String) {
        self.place = place
        self.sessionId = sessionId
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

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
        if let mv = filteredPreview {
            mv.frame = view.bounds
            let s = UIScreen.main.scale
            mv.drawableSize = CGSize(width: view.bounds.width * s, height: view.bounds.height * s)
        }
        layoutBottomUI()
        layoutTipChip()
        // 전환 버튼 위치 갱신
        view.viewWithTag(902)?.frame = CGRect(x: view.bounds.width - 64, y: 60, width: 44, height: 44)
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

        // 필터 프리뷰 — 기본(필터 없음)일 땐 숨겨져 기존 previewLayer가 그대로 보인다
        let metalView = FilteredPreviewMTKView(frame: view.bounds)
        metalView.isHidden = true
        view.addSubview(metalView)
        filteredPreview = metalView

        // 닫기 버튼
        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeBtn.tintColor = .white
        closeBtn.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeBtn.layer.cornerRadius = 22
        closeBtn.frame = CGRect(x: 20, y: 60, width: 44, height: 44)
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeBtn)

        // 장소명 레이블
        let placeL = UILabel()
        placeL.text = place.placeName
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

        // 나루 무드 필터 바
        filterBar.axis = .horizontal
        filterBar.spacing = 8
        view.addSubview(filterBar)
        for filter in NaruFilter.allCases {
            let b = UIButton(type: .system)
            b.setTitle(L(filter.titleKey), for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            b.tintColor = .white
            b.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            b.layer.cornerRadius = 16
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            b.tag = 950 + filter.rawValue
            b.addTarget(self, action: #selector(filterTapped(_:)), for: .touchUpInside)
            filterBar.addArrangedSubview(b)
        }

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

    private func checkAndStartCamera() {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)

        func startIfPossible() {
            service.configure()
            service.onRecordingFinished = { [weak self] url in
                DispatchQueue.main.async { self?.recordingDone(url: url) }
            }
            // 필터 적용 프레임을 Metal 프리뷰로 전달 (필터 활성 시에만 방출됨)
            service.onPreviewImage = { [weak self] image in
                DispatchQueue.main.async { self?.filteredPreview?.display(image: image) }
            }
            // 저장된 마지막 필터 복원
            self.applyFilter(NaruFilter.saved)
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
                        self?.showPermissionOverlay()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionOverlay()
        @unknown default:
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

        let label = UILabel()
        label.text = L("camera.saving")
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.tag = 703

        stack.addArrangedSubview(indicator)
        stack.addArrangedSubview(checkMark)
        stack.addArrangedSubview(label)

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
        let currentClipURL = VlogService.clipURL(place: place, sessionId: sessionId)
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
        }
    }

    /// 녹화 버튼 링 = 이번 클립 진행률 (녹화 중에만 채워짐)
    private func updateClipGauge() {
        guard let start = recordStart else { return }
        let clipFrac = min(1, max(0, Date().timeIntervalSince(start) / max(currentClipLimit, 0.1)))
        clipProgress.strokeEnd = CGFloat(clipFrac)
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
        clipHint.text = ProManager.shared.isPro ? L("camera.clipHintPro") : L("camera.clipHintFree")
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
        // 버튼 바로 아래 클립 힌트
        clipHint.sizeToFit()
        clipHint.frame.origin = CGPoint(
            x: (w - clipHint.frame.width) / 2,
            y: zoomBar.frame.minY - clipHint.frame.height - 12
        )
        recordBtn.center = CGPoint(x: w / 2, y: clipHint.frame.minY - 12 - 40)
        // 필터 바 — 녹화 버튼 위에 가로 중앙 정렬
        let fSize = filterBar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        filterBar.frame = CGRect(
            x: (w - fSize.width) / 2,
            y: recordBtn.frame.minY - fSize.height - 16,
            width: fSize.width, height: fSize.height
        )
    }

    // MARK: - Actions
    @objc private func closeTapped() { onClose?() }

    @objc private func flipTapped() {
        service.flipCamera()
        let isFront = service.currentCameraPosition == .front
        zoomBar.isHidden = isFront
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
        clipProgress.strokeEnd = 0
        service.startRecording(place: place, sessionId: sessionId)
        setInnerDot(recording: true)
        hintLabel.text = recordingHint
        recordStart = Date()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let s = self.recordStart else { return }
            let elapsed = Date().timeIntervalSince(s)
            self.updateClipGauge()
            // 녹화 중 버튼 아래 힌트를 이번 클립 경과/상한으로 갱신 (예: "2.3 / 5초")
            self.clipHint.text = L("camera.clipElapsed",
                                   String(format: "%.1f", min(elapsed, clipLimit)),
                                   Int(clipLimit.rounded()))
            // 클립 한도 도달 — CameraService도 maxDuration에서 자동 종료된다
            if elapsed >= clipLimit {
                self.stopRecordingUI()
            }
        }
    }

    private func stopRecordingUI() {
        progressTimer?.invalidate()
        progressTimer = nil
        savingOverlay?.isHidden = false
        view.isUserInteractionEnabled = false
        service.stopRecording()
    }

    @objc private func filterTapped(_ sender: UIButton) {
        guard let filter = NaruFilter(rawValue: sender.tag - 950) else { return }
        applyFilter(filter)
        NaruFilter.saved = filter
    }

    private func applyFilter(_ filter: NaruFilter) {
        service.activeFilter = filter
        // 필터가 켜지면 Metal 프리뷰를 표시하고, 꺼지면 기존 하드웨어 프리뷰로 복귀
        filteredPreview?.isHidden = (filter == .none)
        for v in filterBar.arrangedSubviews {
            guard let b = v as? UIButton else { continue }
            let selected = (b.tag - 950) == filter.rawValue
            b.backgroundColor = selected ? .white : UIColor.black.withAlphaComponent(0.45)
            b.tintColor = selected ? .black : .white
        }
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
        refreshUsedSeconds()   // 파일 기준으로 재계산 (재촬영 덮어쓰기 반영)
        clipProgress.strokeEnd = 0
        clipHint.text = ProManager.shared.isPro ? L("camera.clipHintPro") : L("camera.clipHintFree")
        hintLabel.text = idleHint
        setInnerDot(recording: false)
        
        if url != nil {
            // 저장 성공 UI 업데이트
            savingOverlay?.viewWithTag(701)?.isHidden = true // indicator
            savingOverlay?.viewWithTag(702)?.isHidden = false // checkMark
            if let label = savingOverlay?.viewWithTag(703) as? UILabel {
                label.text = L("camera.saveSuccess")
            }
            
            // 1.2초 대기 후 자동 닫기
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.onSaved?()
                self?.dismiss(animated: true)
            }
        } else {
            // 취소되거나 오류 시 오버레이 숨기기
            savingOverlay?.isHidden = true
            view.isUserInteractionEnabled = true
        }
    }

    private func setInnerDot(recording: Bool) {
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
