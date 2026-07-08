import AVFoundation
import Foundation
import UIKit

class CameraService: NSObject {
    let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private(set) var currentCameraPosition: AVCaptureDevice.Position = .back
    // 가상 멀티렌즈 기기 사용 시, UI '1x'에 해당하는 실제 videoZoomFactor (초광각 포함 기기는 보통 2.0)
    private var zoomBaseFor1x: CGFloat = 1.0
    private var hasUltraWide = false
    // 중력 센서 기반 물리 방향 추적 — 화면 세로 잠금 상태에서도 가로 촬영을 정확히 감지
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var videoDataOutput = AVCaptureVideoDataOutput()
    private var audioDataOutput = AVCaptureAudioDataOutput()

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var outputURL: URL?

    /// 실제 첫 비디오 프레임이 기록되기 시작한 순간 콜백 — 카메라 워밍업 지연을 감안해
    /// 클립 타이머를 '첫 프레임' 기준으로 맞춰 첫 촬영이 짧게 잘리는 문제를 막는다.
    var onRecordingStarted: (() -> Void)?

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

        // 비디오 — 가상 멀티렌즈 기기(트리플/듀얼와이드)를 단일 입력으로 사용한다.
        // 0.5x/1x/3x·핀치 줌을 전부 videoZoomFactor로 처리해 렌즈 전환 시 세션 재구성을 없앤다
        // (기존엔 0.5x↔1x가 입력 교체 → 메인 스레드 재구성으로 버벅였음).
        guard let device = bestVideoDevice(position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(videoInput) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(videoInput)
        videoDevice = device
        currentCameraPosition = .back
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        updateZoomBase(for: device)
        // 기본은 1x(광각). 가상 기기 기본값은 초광각(0.5x)이라 명시적으로 맞춘다.
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = zoomBaseFor1x
            device.unlockForConfiguration()
        }

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
        applyStabilization()

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
        // 후면은 가상 멀티렌즈, 전면은 광각. (전/후면 전환은 사용자의 명시적 동작이라 재구성이 불가피)
        guard let newDevice = bestVideoDevice(position: newPosition),
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
            updateZoomBase(for: newDevice)
            if (try? newDevice.lockForConfiguration()) != nil {
                newDevice.videoZoomFactor = zoomBaseFor1x
                newDevice.unlockForConfiguration()
            }
        }
        captureSession.commitConfiguration()
        applyStabilization()
    }

    // MARK: - 카메라 기기 선택
    /// 후면: 초광각·광각·망원을 아우르는 가상 기기 우선(트리플→듀얼와이드→듀얼→광각). 전면: 광각.
    private func bestVideoDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        guard position == .back else {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        }
        return AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// UI '1x'에 해당하는 videoZoomFactor를 계산한다. 초광각을 포함한 가상 기기는
    /// 초광각→광각 스위치오버 지점이 곧 1x(보통 2.0), 그 외엔 1.0.
    private func updateZoomBase(for device: AVCaptureDevice) {
        let hasUW = device.deviceType == .builtInUltraWideCamera
            || device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        hasUltraWide = hasUW
        if hasUW, let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            zoomBaseFor1x = CGFloat(truncating: first)
        } else {
            zoomBaseFor1x = 1.0
        }
    }

    // MARK: - 손떨림 방지
    /// 비디오 데이터 출력 커넥션에 자동 손떨림 보정을 적용한다.
    /// 기기 전환(전/후면·줌 렌즈 교체) 후에도 커넥션이 새로 생기므로 다시 호출한다.
    private func applyStabilization() {
        guard let connection = videoDataOutput.connection(with: .video),
              connection.isVideoStabilizationSupported else { return }
        // .auto는 기기에 따라 시네마틱 계열(프레임 전달 지연 1초+)을 선택해
        // 클립 시작 구간 무음·링 타이머 어긋남을 키운다 → 지연이 거의 없는 .standard 고정
        connection.preferredVideoStabilizationMode = .standard
    }

    // MARK: - 핀치 줌 / 탭 초점
    /// 현재 활성 비디오 기기의 줌 배율(광각 렌즈 기준 1.0~)
    var currentZoomFactor: Double { Double(videoDevice?.videoZoomFactor ?? 1) }

    /// 핀치 등으로 연속 줌을 조정한다(단위: 실제 videoZoomFactor). 가상 기기에서는
    /// 하한(초광각)까지 내려가 0.5x도 연속으로 도달하며, 렌즈 전환은 시스템이 광학으로 처리한다.
    func setContinuousZoom(_ factor: Double) {
        guard let d = videoDevice else { return }
        let minF = d.minAvailableVideoZoomFactor
        let maxF = min(d.maxAvailableVideoZoomFactor, zoomBaseFor1x * 10) // 과도한 디지털 줌 방지
        let clamped = CGFloat(max(Double(minF), min(factor, Double(maxF))))
        guard (try? d.lockForConfiguration()) != nil else { return }
        d.videoZoomFactor = clamped
        d.unlockForConfiguration()
    }

    /// 프리뷰에서 탭한 지점(0~1로 정규화된 기기 좌표)에 초점·노출을 맞춘다.
    func focus(at devicePoint: CGPoint) {
        guard let d = videoDevice else { return }
        guard (try? d.lockForConfiguration()) != nil else { return }
        if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
            d.focusPointOfInterest = devicePoint
            d.focusMode = .continuousAutoFocus
        }
        if d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure) {
            d.exposurePointOfInterest = devicePoint
            d.exposureMode = .continuousAutoExposure
        }
        d.unlockForConfiguration()
    }

    // MARK: - Zoom (프리셋 0.5/1/3x)
    var availableZoomFactors: [Double] {
        var factors: [Double] = []
        if hasUltraWide { factors.append(0.5) }
        factors.append(1.0)
        if let d = videoDevice, d.maxAvailableVideoZoomFactor >= zoomBaseFor1x * 3 { factors.append(3.0) }
        return factors
    }

    /// UI 배율(0.5/1/3x)로 부드럽게 줌한다. 렌즈 전환은 videoZoomFactor 변경만으로 시스템이
    /// 광학 처리하므로 세션 재구성이 없다. ramp로 애니메이션(기본 카메라와 유사한 느낌).
    func setZoom(_ uiFactor: Double) {
        guard let d = videoDevice else { return }
        let target = min(max(zoomBaseFor1x * CGFloat(uiFactor), d.minAvailableVideoZoomFactor),
                         d.maxAvailableVideoZoomFactor)
        guard (try? d.lockForConfiguration()) != nil else { return }
        d.ramp(toVideoZoomFactor: target, withRate: 14)
        d.unlockForConfiguration()
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

        // 세션 시작 — 실제 첫 비디오 프레임이 도착한 순간. 카메라 워밍업 지연을 감안해
        // 이 시점을 UI 타이머의 기준으로 삼아 첫 촬영이 짧게 잘리지 않게 한다.
        if !isWritingSessionStarted {
            guard isVideo else { return }
            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
            isWritingSessionStarted = true
            recordingStartTime = timestamp
            DispatchQueue.main.async { [weak self] in self?.onRecordingStarted?() }
        }

        // 최대 시간 체크 — 반드시 '비디오 프레임' PTS로만 판정한다.
        // 손떨림 보정 파이프라인이 비디오를 지연 전달(PTS는 실제 촬영 시각)하는 동안
        // 오디오는 거의 실시간으로 도착해 오디오 PTS가 항상 비디오보다 앞서 달린다.
        // 오디오로 판정하면 (상한 − 파이프라인 지연)초 만에 조기 종료돼
        // 링 UI가 끝까지 차지 않고 비디오 트랙도 상한보다 짧게 잘린다.
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(timestamp, recordingStartTime))
        if isVideo {
            if elapsed >= maxDuration {
                if isRecording { finishRecording() }
                return
            }
            if videoInput.isReadyForMoreMediaData { videoInput.append(sampleBuffer) }
        } else if elapsed < maxDuration, audioInput.isReadyForMoreMediaData {
            // 오디오는 비디오와 같은 상한 구간까지만 기록해 두 트랙 길이를 맞춘다
            audioInput.append(sampleBuffer)
        }
    }
}
