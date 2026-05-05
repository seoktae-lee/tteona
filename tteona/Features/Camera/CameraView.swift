import SwiftUI
import AVFoundation
import UIKit

struct CameraView: View {
    let place: Place
    let sessionId: String
    @Environment(\.dismiss) private var dismiss

    @State private var recordedClipURL: URL?

    var body: some View {
        if let url = recordedClipURL {
            PostShotMemoView(clipURL: url, place: place, sessionId: sessionId) {
                dismiss()
            }
        } else {
            CameraViewControllerWrapper(place: place, sessionId: sessionId) { url in
                recordedClipURL = url
            } onClose: {
                dismiss()
            }
        }
    }
}

struct CameraViewControllerWrapper: UIViewControllerRepresentable {
    let place: Place
    let sessionId: String
    let onRecorded: (URL) -> Void
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController(place: place, sessionId: sessionId)
        vc.onRecorded = onRecorded
        vc.onDismiss = onClose
        return vc
    }
    func updateUIViewController(_ vc: CameraViewController, context: Context) {}
}

// MARK: - CameraViewController
final class CameraViewController: UIViewController {
    var onDismiss: (() -> Void)?
    var onRecorded: ((URL) -> Void)?

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
        service.configure()
        service.onRecordingFinished = { [weak self] url in
            DispatchQueue.main.async { self?.recordingDone(url: url) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    // MARK: - Build UI (frame 기반 — Auto Layout 충돌 없음)
    private func buildUI() {
        // 프리뷰
        previewLayer.session = service.captureSession
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        // 닫기
        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeBtn.tintColor = .white
        closeBtn.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeBtn.layer.cornerRadius = 22
        closeBtn.frame = CGRect(x: 20, y: 60, width: 44, height: 44)
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeBtn)

        // 장소명
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

        // 가로 촬영 안내
        let landscapeHint = UILabel()
        landscapeHint.text = "📱 가로로 돌려서 촬영하세요"
        landscapeHint.textColor = .white
        landscapeHint.font = .systemFont(ofSize: 13, weight: .medium)
        landscapeHint.textAlignment = .center
        landscapeHint.backgroundColor = UIColor(red: 1, green: 0.42, blue: 0.21, alpha: 0.85)
        landscapeHint.layer.cornerRadius = 12
        landscapeHint.clipsToBounds = true
        landscapeHint.sizeToFit()
        landscapeHint.frame = CGRect(x: 0, y: 0, width: landscapeHint.frame.width + 24, height: 32)
        landscapeHint.center = CGPoint(x: view.bounds.midX, y: 124)
        view.addSubview(landscapeHint)

        // 힌트
        hintLabel.text = "버튼을 누르고 있는 동안 촬영"
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textAlignment = .center
        hintLabel.sizeToFit()
        view.addSubview(hintLabel)

        // 줌 바
        zoomBar.axis = .horizontal
        zoomBar.spacing = 8
        view.addSubview(zoomBar)
        for (title, factor) in [(".5x", 0.5), ("1x", 1.0), ("3x", 3.0)] as [(String, Double)] {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            b.tintColor = .white
            b.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            b.layer.cornerRadius = 22
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            b.heightAnchor.constraint(equalToConstant: 44).isActive = true
            b.tag = Int(factor * 10)
            b.addTarget(self, action: #selector(zoomTapped(_:)), for: .touchUpInside)
            zoomBar.addArrangedSubview(b)
        }
        setZoomSelected(1.0)

        // 타이머 링 + 숫자
        buildProgressRing()

        // 녹화 버튼 (frame, addTarget)
        buildRecordButton()

        // 레이아웃
        layoutBottomUI()
    }

    private func buildProgressRing() {
        let size: CGFloat = 60
        let c = CGPoint(x: size/2, y: size/2)
        let bg = CAShapeLayer()
        bg.path = UIBezierPath(arcCenter: c, radius: 26, startAngle: -.pi/2, endAngle: .pi*1.5, clockwise: true).cgPath
        bg.strokeColor = UIColor.white.withAlphaComponent(0.2).cgColor
        bg.fillColor = UIColor.clear.cgColor
        bg.lineWidth = 4

        progressRing.path = bg.path
        progressRing.strokeColor = UIColor(red:1, green:0.42, blue:0.21, alpha:1).cgColor
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

        countLabel.text = "10"
        countLabel.textColor = .white
countLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        countLabel.textAlignment = .center
        countLabel.frame = CGRect(x: 0, y: 0, width: size, height: size)
        container.addSubview(countLabel)
    }

    private func buildRecordButton() {
        recordBtn.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        recordBtn.addTarget(self, action: #selector(recordDown), for: .touchDown)
        recordBtn.addTarget(self, action: #selector(recordUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        view.addSubview(recordBtn)

        let c = CGPoint(x: 40, y: 40)
        outerRing.path = UIBezierPath(arcCenter: c, radius: 38, startAngle: 0, endAngle: .pi*2, clockwise: true).cgPath
        outerRing.strokeColor = UIColor.white.cgColor
        outerRing.fillColor = UIColor.clear.cgColor
        outerRing.lineWidth = 4
        recordBtn.layer.addSublayer(outerRing)

        innerDot.path = UIBezierPath(arcCenter: c, radius: 30, startAngle: 0, endAngle: .pi*2, clockwise: true).cgPath
        innerDot.fillColor = UIColor.red.cgColor
        recordBtn.layer.addSublayer(innerDot)
    }

    private func layoutBottomUI() {
        let w = view.bounds.width
        let safeBottom = view.safeAreaInsets.bottom > 0 ? view.safeAreaInsets.bottom : 34

        hintLabel.sizeToFit()
        hintLabel.frame.origin = CGPoint(
            x: (w - hintLabel.frame.width) / 2,
            y: view.bounds.height - safeBottom - hintLabel.frame.height - 8
        )

        zoomBar.sizeToFit()
        let zoomW = CGFloat(zoomBar.arrangedSubviews.count) * 44 + CGFloat(zoomBar.arrangedSubviews.count - 1) * 8
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        layoutBottomUI()
    }

    // MARK: - Actions
    @objc private func closeTapped() { onDismiss?() }

    @objc private func recordDown() {
        service.startRecording(place: place, sessionId: sessionId)
        setInnerDot(recording: true)
        hintLabel.text = "손을 떼면 저장됩니다 (최대 10초)"
        view.viewWithTag(901)?.alpha = 1
        recordStart = Date()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let s = self.recordStart else { return }
            let p = min(Date().timeIntervalSince(s) / 10.0, 1.0)
            self.progressRing.strokeEnd = CGFloat(p)
            self.countLabel.text = "\(max(0, Int(ceil((1-p)*10))))"
        }
    }

    @objc private func recordUp() {
        service.stopRecording()
    }

    @objc private func zoomTapped(_ sender: UIButton) {
        let f = Double(sender.tag) / 10.0
        service.setZoom(f)
        setZoomSelected(f)
    }

    // MARK: - Helpers
    private func recordingDone(url: URL?) {
        progressTimer?.invalidate()
        progressTimer = nil
        progressRing.strokeEnd = 0
        countLabel.text = "10"
        view.viewWithTag(901)?.alpha = 0.3
        hintLabel.text = "버튼을 누르고 있는 동안 촬영"
        setInnerDot(recording: false)
        if let url {
            onRecorded?(url)
        } else {
            onDismiss?()
        }
    }

    private func setInnerDot(recording: Bool) {
        let c = CGPoint(x: 40, y: 40)
        let to: CGPath = recording
            ? UIBezierPath(roundedRect: CGRect(x: 24, y: 24, width: 32, height: 32), cornerRadius: 8).cgPath
            : UIBezierPath(arcCenter: c, radius: 30, startAngle: 0, endAngle: .pi*2, clockwise: true).cgPath
        let a = CABasicAnimation(keyPath: "path")
        a.fromValue = innerDot.path; a.toValue = to; a.duration = 0.2
        innerDot.add(a, forKey: nil); innerDot.path = to
    }

    private func setZoomSelected(_ factor: Double) {
        for v in zoomBar.arrangedSubviews {
            guard let b = v as? UIButton else { continue }
            let selected = Double(b.tag)/10.0 == factor
            b.backgroundColor = selected ? .white : UIColor.black.withAlphaComponent(0.45)
            b.tintColor = selected ? .black : .white
        }
    }
}
