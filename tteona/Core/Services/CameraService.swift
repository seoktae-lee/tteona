import AVFoundation
import Foundation
import Combine

@MainActor
class CameraService: NSObject, ObservableObject {
    let captureSession = AVCaptureSession()
    private var movieOutput = AVCaptureMovieFileOutput()
    private var recordingTimer: Timer?

    @Published var isRecording = false
    @Published var recordingProgress: Double = 0
    @Published var recordingFinished = false

    private let maxDuration: TimeInterval = 10.0
    private var currentPlace: Place?
    private var currentSessionId: String?

    // MARK: - Setup
    func configure() {
        Task.detached {
            await self.setupSession()
        }
    }

    private func setupSession() async {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoInput) else {
            return
        }
        captureSession.addInput(videoInput)

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }

        captureSession.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }

    func stopSession() {
        captureSession.stopRunning()
        stopTimer()
    }

    // MARK: - Recording
    func startRecording(place: Place, sessionId: String) {
        guard !isRecording else { return }
        currentPlace = place
        currentSessionId = sessionId

        let url = videoOutputURL(place: place, sessionId: sessionId)
        createDirectoryIfNeeded(for: url)

        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        recordingProgress = 0
        startTimer()
    }

    func stopRecording() {
        guard isRecording else { return }
        movieOutput.stopRecording()
        stopTimer()
        isRecording = false
    }

    // MARK: - Timer
    private func startTimer() {
        let start = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(start)
            let progress = min(elapsed / self.maxDuration, 1.0)
            Task { @MainActor in
                self.recordingProgress = progress
                if progress >= 1.0 {
                    self.stopRecording()
                }
            }
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
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
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate
extension CameraService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                 didFinishRecordingTo outputFileURL: URL,
                                 from connections: [AVCaptureConnection],
                                 error: Error?) {
        Task { @MainActor in
            self.recordingProgress = 0
            self.recordingFinished = true
        }
    }
}
