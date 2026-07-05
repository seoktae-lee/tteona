import AVFoundation
import Foundation
import UIKit

class CameraService: NSObject {
    let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private(set) var currentCameraPosition: AVCaptureDevice.Position = .back
    // 중력 센서 기반 물리 방향 추적 — 화면 세로 잠금 상태에서도 가로 촬영을 정확히 감지
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var videoDataOutput = AVCaptureVideoDataOutput()
    private var audioDataOutput = AVCaptureAudioDataOutput()

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var outputURL: URL?

    private let writingQueue = DispatchQueue(label: "camera.writing")
    private var isWritingSessionStarted = false
    private(set) var isRecording = false

    /// 이번 클립의 최대 길이(초) — 촬영 시작 전에 남은 세션 예산으로 설정된다
    var maxDuration: TimeInterval = 5.0
    private var recordingStartTime: CMTime = .zero

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
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)

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

    // MARK: - 전면/후면 전환
    func flipCamera() {
        guard !isRecording else { return }
        let newPosition: AVCaptureDevice.Position = currentCameraPosition == .back ? .front : .back
        guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

        captureSession.beginConfiguration()
        captureSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.video) }
            .forEach { captureSession.removeInput($0) }
        if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
            videoDevice = newDevice
            currentCameraPosition = newPosition
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: newDevice, previewLayer: nil)
        }
        captureSession.commitConfiguration()
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
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: newDevice, previewLayer: nil)
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

        // 센서 버퍼는 1920×1080 landscape로 받되, 회전 메타(transform)를 기록해
        // 재생·합성(로컬 AVFoundation/서버 FFmpeg) 시 자동으로 바로 서게 한다.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        // 물리 방향 기준 회전 메타 — 세로 잠금이 걸려 있어도 가로 촬영이 바로 서게 기록
        videoInput.transform = currentVideoTransform()

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
            self.isRecording = true
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        finishRecording()
    }

    private func finishRecording() {
        writingQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter, self.isRecording else { return }
            self.isRecording = false
            self.videoWriterInput?.markAsFinished()
            self.audioWriterInput?.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async {
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

    func cancelRecording() {
        guard isRecording else { return }
        writingQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter, self.isRecording else { return }
            self.isRecording = false
            self.videoWriterInput?.markAsFinished()
            self.audioWriterInput?.markAsFinished()
            writer.cancelWriting()
            
            let url = self.outputURL
            self.assetWriter = nil
            self.videoWriterInput = nil
            self.audioWriterInput = nil
            self.outputURL = nil
            self.isWritingSessionStarted = false
            
            if let url = url {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers
    private func videoOutputURL(place: Place, sessionId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)")
        // clipFileName이 있으면 사용, 없으면 order+장소명 fallback (코스 기반 세션)
        let name = place.clipFileName ?? {
            let safeName = place.placeName
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            return "\(place.order)_\(safeName).mp4"
        }()
        return dir.appendingPathComponent(name)
    }

    private func createDirectoryIfNeeded(for url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    // 물리 방향 → 영상 회전 메타. 센서 버퍼가 landscape이므로 세로 촬영이면 90° 회전 기록.
    // RotationCoordinator는 중력 센서 기반이라 화면 세로 잠금·faceUp 상태에서도 정확하다.
    private func currentVideoTransform() -> CGAffineTransform {
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture {
            return CGAffineTransform(rotationAngle: angle * .pi / 180)
        }
        // 폴백: 기기 방향 (세로 잠금 시 부정확할 수 있음)
        switch UIDevice.current.orientation {
        case .landscapeLeft:       return .identity                          // 홈버튼(하단) 오른쪽
        case .landscapeRight:      return CGAffineTransform(rotationAngle: .pi)
        case .portraitUpsideDown:  return CGAffineTransform(rotationAngle: -.pi / 2)
        default:                   return CGAffineTransform(rotationAngle: .pi / 2)  // 세로(기본)
        }
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
