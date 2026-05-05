import AVFoundation
import Foundation

class CameraService: NSObject {
    let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private var videoDataOutput = AVCaptureVideoDataOutput()
    private var audioDataOutput = AVCaptureAudioDataOutput()

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var outputURL: URL?

    private let writingQueue = DispatchQueue(label: "camera.writing")
    private var isWritingSessionStarted = false
    private(set) var isRecording = false

    private let maxDuration: TimeInterval = 10.0
    private let minDuration: TimeInterval = 2.0
    private var recordingStartTime: CMTime = .zero
    private var stopRequested = false
    private var minDurationTimer: Timer?

    var onRecordingFinished: ((URL?) -> Void)?

    // MARK: - Setup
    func configure() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setupSession()
        }
    }

    private func setupSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080

        // 비디오
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(videoInput) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(videoInput)
        videoDevice = device

        // 오디오
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }

        // 비디오 데이터 출력
        videoDataOutput.setSampleBufferDelegate(self, queue: writingQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }

        // 오디오 데이터 출력
        audioDataOutput.setSampleBufferDelegate(self, queue: writingQueue)
        if captureSession.canAddOutput(audioDataOutput) {
            captureSession.addOutput(audioDataOutput)
        }

        captureSession.commitConfiguration()
        captureSession.startRunning()
    }

    func stopSession() {
        captureSession.stopRunning()
    }

    // MARK: - Zoom
    var availableZoomFactors: [Double] {
        var factors: [Double] = []
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
            factors.append(0.5)
        }
        factors.append(1.0)
        if let d = videoDevice, min(d.activeFormat.videoMaxZoomFactor, 15) >= 3 {
            factors.append(3.0)
        }
        return factors
    }

    func setZoom(_ factor: Double) {
        if factor == 0.5 {
            switchCamera(to: .builtInUltraWideCamera, zoom: 1.0)
        } else {
            if let input = captureSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }),
               input.device.deviceType == .builtInUltraWideCamera {
                switchCamera(to: .builtInWideAngleCamera, zoom: factor)
            } else if let d = videoDevice {
                try? d.lockForConfiguration()
                d.videoZoomFactor = CGFloat(max(1, min(factor, d.activeFormat.videoMaxZoomFactor)))
                d.unlockForConfiguration()
            }
        }
    }

    private func switchCamera(to type: AVCaptureDevice.DeviceType, zoom: Double) {
        guard let newDevice = AVCaptureDevice.default(type, for: .video, position: .back),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }
        captureSession.beginConfiguration()
        captureSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.video) }
            .forEach { captureSession.removeInput($0) }
        if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
            videoDevice = newDevice
            try? newDevice.lockForConfiguration()
            newDevice.videoZoomFactor = CGFloat(zoom)
            newDevice.unlockForConfiguration()
        }
        captureSession.commitConfiguration()
    }

    // MARK: - Recording
    func startRecording(place: Place, sessionId: String) {
        guard !isRecording else { return }

        let url = videoOutputURL(place: place, sessionId: sessionId)
        createDirectoryIfNeeded(for: url)
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

        // 센서는 항상 가로(1920×1080)로 데이터를 보냄
        // transform으로 90° 회전을 파일에 기록 → 플레이어/VlogService가 세로로 인식
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        // 세로 촬영: 90° 회전 (b=1, a=0, tx=0, ty=naturalSize.width=1080)
        videoInput.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 1920)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        writer.add(videoInput)
        writer.add(audioInput)

        writingQueue.async { [weak self] in
            guard let self else { return }
            self.assetWriter = writer
            self.videoWriterInput = videoInput
            self.audioWriterInput = audioInput
            self.outputURL = url
            self.isWritingSessionStarted = false
            self.stopRequested = false
            self.isRecording = true
        }

        // 최소 2초 보호 타이머
        DispatchQueue.main.async {
            self.minDurationTimer?.invalidate()
            self.minDurationTimer = Timer.scheduledTimer(withTimeInterval: self.minDuration, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.minDurationTimer = nil
                if self.stopRequested { self.finishRecording() }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        if minDurationTimer != nil {
            stopRequested = true
        } else {
            finishRecording()
        }
    }

    private func finishRecording() {
        writingQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter, self.isRecording else { return }
            self.isRecording = false
            self.videoWriterInput?.markAsFinished()
            self.audioWriterInput?.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async {
                    self.minDurationTimer?.invalidate()
                    self.minDurationTimer = nil
                    let url = self.outputURL
                    self.assetWriter = nil
                    self.videoWriterInput = nil
                    self.audioWriterInput = nil
                    self.outputURL = nil
                    self.isWritingSessionStarted = false
                    self.onRecordingFinished?(url)
                }
            }
        }
    }

    // MARK: - Helpers
    private func videoOutputURL(place: Place, sessionId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)")
        let name = "\(place.order)_\(place.placeName.replacingOccurrences(of: " ", with: "_")).mp4"
        return dir.appendingPathComponent(name)
    }

    private func createDirectoryIfNeeded(for url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}

// MARK: - Sample Buffer Delegate
extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording,
              let writer = assetWriter,
              let videoInput = videoWriterInput,
              let audioInput = audioWriterInput else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let isVideo = output is AVCaptureVideoDataOutput

        // 세션 시작
        if !isWritingSessionStarted {
            guard isVideo else { return }
            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
            isWritingSessionStarted = true
            recordingStartTime = timestamp
        }

        // 최대 시간 체크
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(timestamp, recordingStartTime))
        if elapsed >= maxDuration {
            if isRecording { finishRecording() }
            return
        }

        // 버퍼 쓰기
        if isVideo, videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        } else if !isVideo, audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }
}
