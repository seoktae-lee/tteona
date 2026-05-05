import SwiftUI
import AVFoundation

struct CameraView: View {
    let place: Place
    let sessionId: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cameraService = CameraService()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: cameraService.captureSession)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomControls
            }
        }
        .onAppear {
            cameraService.configure()
        }
        .onDisappear {
            cameraService.stopSession()
        }
        .onChange(of: cameraService.recordingFinished) { _, finished in
            if finished { dismiss() }
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            Spacer()
            Text(place.placeName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.5)))
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
    }

    private var bottomControls: some View {
        VStack(spacing: 20) {
            TimerProgressView(progress: cameraService.recordingProgress)

            HStack {
                Spacer()
                // 시각적 버튼 + UIKit 터치 오버레이
                RecordButtonVisual(isRecording: cameraService.isRecording)
                    .overlay(
                        // cameraService는 @StateObject라 항상 동일 인스턴스
                        RecordTouchOverlay(
                            onPress: { cameraService.startRecording(place: place, sessionId: sessionId) },
                            onRelease: { cameraService.stopRecording() }
                        )
                    )
                Spacer()
            }

            ZoomSelector(
                factors: cameraService.availableZoomFactors,
                current: cameraService.currentZoomFactor
            ) { cameraService.setZoom($0) }

            Text(cameraService.isRecording ? "손을 떼면 저장됩니다 (최대 10초)" : "버튼을 누르고 있는 동안 촬영")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.bottom, 50)
    }
}

// MARK: - 시각적 버튼
struct RecordButtonVisual: View {
    let isRecording: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white, lineWidth: 4)
                .frame(width: 80, height: 80)

            RoundedRectangle(cornerRadius: isRecording ? 8 : 35)
                .fill(Color.red)
                .frame(
                    width: isRecording ? 32 : 64,
                    height: isRecording ? 32 : 64
                )
                .animation(.easeInOut(duration: 0.2), value: isRecording)
        }
    }
}

// MARK: - UIKit 터치 오버레이
// Coordinator가 UIView 인스턴스를 소유 — makeUIView는 한 번만 호출됨
struct RecordTouchOverlay: UIViewRepresentable {
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        context.coordinator.touchView.backgroundColor = .clear
        context.coordinator.touchView.isMultipleTouchEnabled = false
        return context.coordinator.touchView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 클로저만 업데이트 — UIView 인스턴스는 교체하지 않음
        context.coordinator.onPress = onPress
        context.coordinator.onRelease = onRelease
    }

    final class Coordinator: NSObject {
        var onPress: (() -> Void)?
        var onRelease: (() -> Void)?

        // Coordinator가 소유 → makeUIView가 여러 번 호출돼도 동일 인스턴스
        lazy var touchView: _RecordTouchUIView = {
            let v = _RecordTouchUIView()
            v.coordinator = self
            return v
        }()
    }
}

final class _RecordTouchUIView: UIView {
    weak var coordinator: RecordTouchOverlay.Coordinator?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        coordinator?.onPress?()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        coordinator?.onRelease?()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        coordinator?.onRelease?()
    }
}

// MARK: - Zoom Selector
struct ZoomSelector: View {
    let factors: [Double]
    let current: Double
    let onSelect: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(factors, id: \.self) { factor in
                let isSelected = current == factor
                Button { onSelect(factor) } label: {
                    Text(label(for: factor))
                        .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? .black : .white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(isSelected ? Color.white : Color.black.opacity(0.45)))
                }
            }
        }
    }

    private func label(for factor: Double) -> String {
        switch factor {
        case 0.5: return ".5x"
        case 1.0: return "1x"
        case 3.0: return "3x"
        default:  return "\(Int(factor))x"
        }
    }
}

// MARK: - Timer Progress
struct TimerProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 4)
                .frame(width: 60, height: 60)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.tteOrange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 60, height: 60)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)

            Text(String(format: "%.0f", ceil((1 - progress) * 10)))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
        .opacity(progress > 0 ? 1 : 0.3)
    }
}

// MARK: - Camera Preview
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        context.coordinator.previewLayer = layer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.previewLayer?.frame = uiView.bounds
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}
