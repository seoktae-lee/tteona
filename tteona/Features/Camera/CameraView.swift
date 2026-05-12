import SwiftUI
import AVFoundation
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
            dismiss()
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
    private let progressRing = CAShapeLayer()
    private let countLabel = UILabel()
    private let hintLabel = UILabel()
    private let zoomBar = UIStackView()
    private var progressTimer: Timer?
    private var recordStart: Date?
    private var landscapeOverlay: UIView?
    private var savingOverlay: UIView?
    private var permissionOverlay: UIView?

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
        landscapeOverlay?.frame = view.bounds
        // 전환 버튼 위치 갱신
        view.viewWithTag(902)?.frame = CGRect(x: view.bounds.width - 64, y: 60, width: 44, height: 44)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        layoutBottomUI()
        layoutLandscapeOverlay()
        // 1.2초 후 fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            UIView.animate(withDuration: 0.5) {
                self?.landscapeOverlay?.alpha = 0
            } completion: { _ in
                self?.landscapeOverlay?.isHidden = true
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
        hintLabel.text = "버튼을 누르면 5초 고정 촬영"
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
        buildProgressRing()
        buildRecordButton()
        buildLandscapeOverlay()
        buildSavingOverlay()
        buildPermissionOverlay()
    }

    private func buildPermissionOverlay() {
        let overlay = UIView(frame: view.bounds)
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        overlay.isHidden = true
        overlay.alpha = 0
        view.addSubview(overlay)
        permissionOverlay = overlay

        let title = UILabel()
        title.text = "카메라 권한이 필요해요"
        title.textColor = .white
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = UILabel()
        subtitle.text = "설정에서 카메라 권한을 허용하면 촬영할 수 있어요."
        subtitle.textColor = UIColor.white.withAlphaComponent(0.75)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let settingsBtn = UIButton(type: .system)
        settingsBtn.setTitle("설정으로 이동", for: .normal)
        settingsBtn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        settingsBtn.tintColor = .white
        settingsBtn.backgroundColor = UIColor(red: 1, green: 0.42, blue: 0.21, alpha: 1)
        settingsBtn.layer.cornerRadius = 14
        settingsBtn.translatesAutoresizingMaskIntoConstraints = false
        settingsBtn.addTarget(self, action: #selector(openSettingsTapped), for: .touchUpInside)

        let closeBtn = UIButton(type: .system)
        closeBtn.setTitle("닫기", for: .normal)
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
        label.text = "영상 저장 중..."
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

    private func buildProgressRing() {
        let size: CGFloat = 60
        let c = CGPoint(x: size / 2, y: size / 2)
        let bg = CAShapeLayer()
        bg.path = UIBezierPath(arcCenter: c, radius: 26, startAngle: -.pi/2, endAngle: .pi*1.5, clockwise: true).cgPath
        bg.strokeColor = UIColor.white.withAlphaComponent(0.2).cgColor
        bg.fillColor = UIColor.clear.cgColor
        bg.lineWidth = 4

        progressRing.path = bg.path
        progressRing.strokeColor = UIColor(red: 1, green: 0.42, blue: 0.21, alpha: 1).cgColor
        progressRing.fillColor = UIColor.clear.cgColor
        progressRing.lineWidth = 4
        progressRing.lineCap = .round
        progressRing.strokeEnd = 0

        let container = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        container.layer.addSublayer(bg)
        container.layer.addSublayer(progressRing)
        container.alpha = 0.3
        container.tag = 901
        view.addSubview(container)

        countLabel.text = "5"
        countLabel.textColor = .white
        countLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        countLabel.textAlignment = .center
        countLabel.frame = CGRect(x: 0, y: 0, width: size, height: size)
        container.addSubview(countLabel)
    }

    private func buildRecordButton() {
        recordBtn.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        recordBtn.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        view.addSubview(recordBtn)

        let c = CGPoint(x: 40, y: 40)
        outerRing.path = UIBezierPath(arcCenter: c, radius: 38, startAngle: 0,
                                      endAngle: .pi*2, clockwise: true).cgPath
        outerRing.strokeColor = UIColor.white.cgColor
        outerRing.fillColor = UIColor.clear.cgColor
        outerRing.lineWidth = 4
        recordBtn.layer.addSublayer(outerRing)

        innerDot.path = UIBezierPath(arcCenter: c, radius: 30, startAngle: 0,
                                     endAngle: .pi*2, clockwise: true).cgPath
        innerDot.fillColor = UIColor.red.cgColor
        recordBtn.layer.addSublayer(innerDot)
    }

    // MARK: - 가로 유도 오버레이
    private func buildLandscapeOverlay() {
        let overlay = UIView()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        view.addSubview(overlay)
        landscapeOverlay = overlay

        // 폰 아이콘 (회전 애니메이션)
        let phoneLabel = UILabel()
        phoneLabel.text = "📱"
        phoneLabel.font = .systemFont(ofSize: 56)
        phoneLabel.textAlignment = .center
        phoneLabel.tag = 811

        let arrowLabel = UILabel()
        arrowLabel.text = "→"
        arrowLabel.font = .systemFont(ofSize: 32, weight: .ultraLight)
        arrowLabel.textColor = UIColor(red: 1, green: 0.42, blue: 0.21, alpha: 1)
        arrowLabel.textAlignment = .center

        // 가로 폰 아이콘
        let phoneLandLabel = UILabel()
        phoneLandLabel.text = "📱"
        phoneLandLabel.font = .systemFont(ofSize: 56)
        phoneLandLabel.textAlignment = .center
        phoneLandLabel.transform = CGAffineTransform(rotationAngle: .pi / 2)

        let iconRow = UIStackView(arrangedSubviews: [phoneLabel, arrowLabel, phoneLandLabel])
        iconRow.axis = .horizontal
        iconRow.spacing = 16
        iconRow.alignment = .center

        let msgLabel = UILabel()
        msgLabel.text = "가로로 돌려서 촬영하세요"
        msgLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        msgLabel.textColor = .white
        msgLabel.textAlignment = .center

        let subLabel = UILabel()
        subLabel.text = "더 넓은 화면으로 여행을 담아보세요"
        subLabel.font = .systemFont(ofSize: 13)
        subLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        subLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [iconRow, msgLabel, subLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.tag = 812
        overlay.addSubview(stack)

        // phoneLabel 흔들기 애니메이션
        UIView.animateKeyframes(withDuration: 1.0, delay: 0.3,
                                options: [.repeat, .calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0,   relativeDuration: 0.35) {
                phoneLabel.transform = CGAffineTransform(rotationAngle: .pi / 2 * 0.75)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.35, relativeDuration: 0.1) {
                phoneLabel.transform = CGAffineTransform(rotationAngle: .pi / 2 * 0.65)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.55) {
                phoneLabel.transform = CGAffineTransform(rotationAngle: .pi / 2 * 0.75)
            }
        }
    }

    private func layoutLandscapeOverlay() {
        guard let overlay = landscapeOverlay,
              let stack = overlay.viewWithTag(812) else { return }
        overlay.frame = view.bounds
        let stackW: CGFloat = 280
        let stackH: CGFloat = 190
        stack.frame = CGRect(
            x: (overlay.bounds.width - stackW) / 2,
            y: (overlay.bounds.height - stackH) / 2,
            width: stackW, height: stackH
        )
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
        recordBtn.center = CGPoint(x: w / 2, y: zoomBar.frame.minY - 40 - 20)
        if let container = view.viewWithTag(901) {
            container.center = CGPoint(x: w / 2, y: recordBtn.frame.minY - 30 - 16)
        }
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
        guard !service.isRecording else { return }
        service.startRecording(place: place, sessionId: sessionId)
        setInnerDot(recording: true)
        hintLabel.text = "5초 촬영 중..."
        view.viewWithTag(901)?.alpha = 1
        recordStart = Date()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let s = self.recordStart else { return }
            let p = min(Date().timeIntervalSince(s) / 5.0, 1.0)
            self.progressRing.strokeEnd = CGFloat(p)
            let remaining = max(0, Int(ceil((1 - p) * 5)))
            self.countLabel.text = "\(remaining)"
            
            // 5초 완료 시점 UI 잠금
            if p >= 1.0 {
                self.savingOverlay?.isHidden = false
                self.view.isUserInteractionEnabled = false
            }
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
        progressRing.strokeEnd = 0
        countLabel.text = "5"
        view.viewWithTag(901)?.alpha = 0.3
        hintLabel.text = "버튼을 누르면 5초 고정 촬영"
        setInnerDot(recording: false)
        
        if url != nil {
            // 저장 성공 UI 업데이트
            savingOverlay?.viewWithTag(701)?.isHidden = true // indicator
            savingOverlay?.viewWithTag(702)?.isHidden = false // checkMark
            if let label = savingOverlay?.viewWithTag(703) as? UILabel {
                label.text = "영상 저장 성공!"
            }
            
            // 1.2초 대기 후 자동 닫기
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.onSaved?()
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
