import AVFoundation
import Foundation
import Combine

@MainActor
class CameraService: NSObject, ObservableObject {
    let captureSession = AVCaptureSession()
    private var movieOutput = AVCaptureMovieFileOutput()
    private var videoDevice: AVCaptureDevice?
    private var progressTimer: Timer?

    @Published var isRecording = false
    @Published var recordingProgress: Double = 0
    @Published var recordingFinished = false
    @Published var currentZoomFactor: Double = 1.0

    var availableZoomFactors: [Double] {
        guard let device = videoDevice else { return [1.0] }
        var factors: [Double] = []
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
            factors.append(0.5)
        }
        factors.append(1.0)
        if min(device.activeFormat.videoMaxZoomFactor, 15.0) >= 3.0 {
            factors.append(3.0)
        }
        return factors
    }

    private let maxDuration: TimeInterval = 10.0
    private var recordingStartTime: Date?

    // MARK: - Setup
    func configure() {
        Task.detached { await self.setupSession() }
    }

    private func setupSession() async {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(videoInput) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(videoInput)

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }

        // maxRecordedDuration으로 10초 자동 종료 — Timer 불필요
        movieOutput.maxRecordedDuration = CMTime(seconds: maxDuration, preferredTimescale: 600)

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }

        captureSession.commitConfiguration()
        await MainActor.run { self.videoDevice = device }

        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }

    func stopSession() {
        captureSession.stopRunning()
        stopProgressTimer()
    }

    // MARK: - Zoom
    func setZoom(_ factor: Double) {
        guard let device = videoDevice else { return }
        if factor == 0.5 {
            switchCamera(to: .builtInUltraWideCamera, zoomFactor: 1.0)
        } else {
            if let input = captureSession.inputs.first as? AVCaptureDeviceInput,
               input.device.deviceType == .builtInUltraWideCamera {
                switchCamera(to: .builtInWideAngleCamera, zoomFactor: factor)
            } else {
                try? device.lockForConfiguration()
                device.videoZoomFactor = CGFloat(max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor)))
                device.unlockForConfiguration()
            }
        }
        currentZoomFactor = factor
    }

    private func switchCamera(to deviceType: AVCaptureDevice.DeviceType, zoomFactor: Double) {
        guard let newDevice = AVCaptureDevice.default(deviceType, for: .video, position: .back),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }
        captureSession.beginConfiguration()
        captureSession.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.video) }
            .forEach { captureSession.removeInput($0) }
        if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
            videoDevice = newDevice
            try? newDevice.lockForConfiguration()
            newDevice.videoZoomFactor = CGFloat(zoomFactor)
            newDevice.unlockForConfiguration()
        }
        captureSession.commitConfiguration()
    }

    // MARK: - Recording
    func startRecording(place: Place, sessionId: String) {
        guard !isRecording, captureSession.isRunning else { return }

        let url = videoOutputURL(place: place, sessionId: sessionId)
        createDirectoryIfNeeded(for: url)

        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        recordingProgress = 0
        recordingStartTime = Date()
        startProgressTimer()
    }

    func stopRecording() {
        guard isRecording else { return }
        movieOutput.stopRecording()
        // isRecording, progress는 delegate에서 정리 — 여기서 바꾸지 않음
        stopProgressTimer()
    }

    // MARK: - Progress Timer (UI 표시 전용 — 실제 종료는 maxRecordedDuration이 담당)
    private func startProgressTimer() {
        let start = recordingStartTime ?? Date()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                self.recordingProgress = min(elapsed / self.maxDuration, 1.0)
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - File Path
    private func videoOutputURL(place: Place, sessionId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionDir = docs
            .appendingPathComponent("Tteona")
            .appendingPathComponent("Sessions")
            .appendingPathComponent(sessionId)
        let filename = "\(place.order)_\(place.placeName.replacingOccurrences(of: " ", with: "_")).mp4"
        return sessionDir.appendingPathComponent(filename)
    }

    private func createDirectoryIfNeeded(for url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate
extension CameraService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        DispatchQueue.main.async {
            self.stopProgressTimer()
            self.isRecording = false
            self.recordingProgress = 0
            self.recordingFinished = true
        }
    }
}
