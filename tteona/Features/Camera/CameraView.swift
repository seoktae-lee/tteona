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

            // 카메라 프리뷰
            CameraPreviewView(session: cameraService.captureSession)
                .ignoresSafeArea()

            VStack {
                // 상단 정보
                topBar
                Spacer()
                // 하단 컨트롤
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
            Button {
                dismiss()
            } label: {
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
            // 타이머 프로그레스
            TimerProgressView(progress: cameraService.recordingProgress)

            HStack {
                Spacer()
                RecordButton(
                    isRecording: cameraService.isRecording,
                    onPress: { cameraService.startRecording(place: place, sessionId: sessionId) },
                    onRelease: { cameraService.stopRecording() }
                )
                Spacer()
            }

            Text(cameraService.isRecording ? "손을 떼면 저장됩니다 (최대 10초)" : "버튼을 누르고 있는 동안 촬영")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.bottom, 60)
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

            Text(String(format: "%.0f", (1 - progress) * 10))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
        .opacity(progress > 0 ? 1 : 0.3)
    }
}

// MARK: - Record Button
struct RecordButton: View {
    let isRecording: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

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
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isRecording { onPress() }
                }
                .onEnded { _ in
                    if isRecording { onRelease() }
                }
        )
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
