import AVFoundation
import UIKit
import Photos

class VlogService {

    // MARK: - Public
    func generateVlog(course: Course, sessionId: String,
                      onProgress: @escaping (Double) -> Void) async throws -> URL {
        let places = course.places

        var segments: [(asset: AVURLAsset, placeName: String, date: Date)] = []
        for place in places {
            let url = Self.clipURL(place: place, sessionId: sessionId)
            guard FileManager.default.fileExists(atPath: url.path) else {
                dlog("[Vlog] skip \(place.placeName) — file not found")
                continue
            }
            segments.append((AVURLAsset(url: url), place.placeName, creationDate(of: url)))
            dlog("[Vlog] found clip: \(url.lastPathComponent)")
        }
        guard !segments.isEmpty else { throw VlogError.noClips }

        await MainActor.run { onProgress(0.1) }

        let outURL = try await buildComposition(segments: segments, onProgress: onProgress)

        await MainActor.run { onProgress(1.0) }
        dlog("[Vlog] done: \(outURL.lastPathComponent)")
        return outURL
    }

    func saveToPhotoLibrary(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    func deleteLocalClips(sessionId: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Composition + CALayer 오버레이 + 페이드 전환
    private func buildComposition(
        segments: [(asset: AVURLAsset, placeName: String, date: Date)],
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {

        let fadeDuration = CMTime(seconds: 0.4, preferredTimescale: 600)
        let comp = AVMutableComposition()

        guard let compVideoTrack = comp.addMutableTrack(withMediaType: .video,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudioTrack = comp.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw VlogError.writeFailed }

        struct SegInfo {
            let placeName: String
            let date: Date
            let startTime: CMTime
            let duration: CMTime
            let size: CGSize            // 회전 반영된 표시 크기 (렌더 크기 결정용)
            let naturalSize: CGSize     // 원본 버퍼 크기 (회전 전)
            let transform: CGAffineTransform  // 클립의 회전 메타 (세로/가로 판별)
        }
        var segInfos: [SegInfo] = []

        // 타이틀 카드: composition 앞에 2초 빈 구간 삽입
        let titleDuration = CMTime(seconds: 2, preferredTimescale: 600)
        let titleDate = segments.first?.date ?? Date()
        comp.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: titleDuration))
        var cursor = titleDuration

        // 클립 순서대로 composition에 삽입
        for (i, seg) in segments.enumerated() {
            let duration = try await seg.asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)

            let videoTracks = try await seg.asset.loadTracks(withMediaType: .video)
            guard let vTrack = videoTracks.first else {
                dlog("[Vlog] skip \(seg.placeName) — no video track")
                continue
            }

            let naturalSize = try await vTrack.load(.naturalSize)
            let transform = try await vTrack.load(.preferredTransform)
            let isPortrait = abs(transform.b) == 1 && abs(transform.c) == 1
            let displaySize = isPortrait
                ? CGSize(width: naturalSize.height, height: naturalSize.width)
                : naturalSize

            try compVideoTrack.insertTimeRange(range, of: vTrack, at: cursor)

            let audioTracks = try await seg.asset.loadTracks(withMediaType: .audio)
            if let aTrack = audioTracks.first {
                try? compAudioTrack.insertTimeRange(range, of: aTrack, at: cursor)
            }

            segInfos.append(SegInfo(
                placeName: seg.placeName,
                date: seg.date,
                startTime: cursor,
                duration: duration,
                size: displaySize,
                naturalSize: naturalSize,
                transform: transform
            ))
            cursor = CMTimeAdd(cursor, duration)

            await MainActor.run { onProgress(0.1 + 0.4 * Double(i + 1) / Double(segments.count)) }
        }

        guard !segInfos.isEmpty else { throw VlogError.writeFailed }

        let outputSize = segInfos[0].size.width > 0 ? segInfos[0].size : CGSize(width: 1920, height: 1080)
        let totalDuration = cursor

        // MARK: VideoComposition — 페이드 인/아웃 + 텍스트 오버레이
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = outputSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        var instructions: [AVMutableVideoCompositionInstruction] = []

        // 타이틀 카드 구간 instruction (빈 트랙 + 주황 배경색)
        let titleInstruction = AVMutableVideoCompositionInstruction()
        titleInstruction.timeRange = CMTimeRange(start: .zero, duration: titleDuration)
        titleInstruction.backgroundColor = UIColor(red: 1.0, green: 0.71, blue: 0.53, alpha: 1.0).cgColor
        titleInstruction.layerInstructions = []
        instructions.append(titleInstruction)

        // 각 클립에 대한 instruction 생성
        for (i, info) in segInfos.enumerated() {
            let clipStart = info.startTime
            let clipDuration = info.duration
            let clipEnd = CMTimeAdd(clipStart, clipDuration)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: clipStart, duration: clipDuration)

            let layerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)

            // 클립의 회전 메타(세로/가로)를 렌더 프레임에 맞춰 적용한다.
            // 이게 없으면 세로 촬영본이 90° 누운 채로 합성된다(로컬 폴백 세로영상 회전 버그).
            // 합성 트랙(compVideoTrack)은 preferredTransform이 항등이라, 원본 클립의
            // 회전 메타를 여기서 직접 걸어줘야 세로·가로 모두 바로 선다.
            let renderTransform = Self.renderTransform(
                preferredTransform: info.transform,
                naturalSize: info.naturalSize,
                renderSize: outputSize
            )
            layerInstr.setTransform(renderTransform, at: clipStart)

            // 페이드 인: 클립 시작 ~ 시작+fadeDuration
            let fadeInEnd = CMTimeAdd(clipStart, fadeDuration)
            layerInstr.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1,
                                       timeRange: CMTimeRange(start: clipStart, end: fadeInEnd))

            // 페이드 아웃: 클립 끝-fadeDuration ~ 클립 끝 (마지막 클립 제외)
            if i < segInfos.count - 1 {
                let fadeOutStart = CMTimeSubtract(clipEnd, fadeDuration)
                layerInstr.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0,
                                           timeRange: CMTimeRange(start: fadeOutStart, end: clipEnd))
            }

            instruction.layerInstructions = [layerInstr]
            instructions.append(instruction)
        }
        videoComp.instructions = instructions

        // MARK: CALayer 오버레이 (텍스트)
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: outputSize)

        let overlayLayer = CALayer()
        overlayLayer.frame = CGRect(origin: .zero, size: outputSize)

        // 타이틀 카드 CALayer (주황 배경 위에 날짜 + tteona 텍스트)
        overlayLayer.addSublayer(
            makeTitleCardLayer(date: titleDate, size: outputSize,
                               titleDuration: titleDuration, totalDuration: totalDuration)
        )

        for info in segInfos {
            let startSec = CMTimeGetSeconds(info.startTime)
            let durSec = CMTimeGetSeconds(info.duration)
            let totalSec = CMTimeGetSeconds(totalDuration)

            let bandLayer = makeTextLayer(
                placeName: info.placeName,
                dateStr: Self.fmt(info.date),
                size: outputSize,
                startSec: startSec,
                clipDuration: durSec,
                totalDuration: totalSec
            )
            overlayLayer.addSublayer(bandLayer)
        }

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: outputSize)
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)

        videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        await MainActor.run { onProgress(0.6) }

        // MARK: Export
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlog_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)

        guard let exp = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw VlogError.writeFailed
        }
        exp.outputURL = outURL
        exp.outputFileType = .mp4
        exp.videoComposition = videoComp

        await MainActor.run { onProgress(0.65) }
        await exp.export()

        dlog("[Vlog] export status=\(exp.status.rawValue) error=\(exp.error?.localizedDescription ?? "none")")
        guard exp.status == .completed else { throw exp.error ?? VlogError.writeFailed }
        return outURL
    }

    // MARK: - 타이틀 카드 CALayer
    private func makeTitleCardLayer(date: Date, size: CGSize, titleDuration: CMTime, totalDuration: CMTime) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: size)
        let totalSec = CMTimeGetSeconds(totalDuration)
        let titleSec = CMTimeGetSeconds(titleDuration)

        let dateLayer = CATextLayer()
        let fontSize = size.height * 0.075
        dateLayer.string = Self.localizedDateString(date)
        dateLayer.font = UIFont(name: "GowunBatang-Regular", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize, weight: .bold)
        dateLayer.fontSize = fontSize
        dateLayer.foregroundColor = UIColor.white.cgColor
        dateLayer.alignmentMode = .center
        dateLayer.contentsScale = UIScreen.main.scale
        dateLayer.frame = CGRect(x: 0, y: (size.height - fontSize * 1.5) / 2, width: size.width, height: fontSize * 1.5)
        container.addSublayer(dateLayer)

        let tteonaLayer = CATextLayer()
        let tteonaSize = size.height * 0.045
        tteonaLayer.string = "tteona"
        tteonaLayer.font = UIFont(name: "GowunBatang-Regular", size: tteonaSize) ?? UIFont.systemFont(ofSize: tteonaSize)
        tteonaLayer.fontSize = tteonaSize
        tteonaLayer.foregroundColor = UIColor.white.withAlphaComponent(0.75).cgColor
        tteonaLayer.alignmentMode = .center
        tteonaLayer.contentsScale = UIScreen.main.scale
        tteonaLayer.frame = CGRect(x: 0, y: size.height * 0.87, width: size.width, height: tteonaSize * 1.5)
        container.addSublayer(tteonaLayer)

        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnim.keyTimes = [0,
                                NSNumber(value: max(0, (titleSec - 0.3) / totalSec)),
                                NSNumber(value: titleSec / totalSec),
                                1]
        opacityAnim.values = [1, 1, 0, 0]
        opacityAnim.duration = totalSec
        opacityAnim.beginTime = 1e-9
        opacityAnim.isRemovedOnCompletion = false
        opacityAnim.fillMode = .both
        container.add(opacityAnim, forKey: "titleOpacity")
        return container
    }

    private static func localizedDateString(_ date: Date) -> String {
        // Vlog 오버레이 날짜 — 선택 언어 로케일의 롱 포맷(예: 2026년 7월 7일 / July 7, 2026)
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)   // 비그레고리력 연도 방지
        f.locale = LanguageManager.shared.locale
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: date)
    }

    // MARK: - CALayer 텍스트 오버레이 생성
    private func makeTextLayer(
        placeName: String,
        dateStr: String,
        size: CGSize,
        startSec: Double,
        clipDuration: Double,
        totalDuration: Double
    ) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: size)

        let W = size.width
        let H = size.height
        let cY = H / 2

        let prostoFont = UIFont(name: "GowunBatang-Regular", size: 80)
            ?? UIFont.systemFont(ofSize: 80, weight: .bold)
        let prostoSmallFont = UIFont(name: "GowunBatang-Regular", size: 52)
            ?? UIFont.systemFont(ofSize: 52, weight: .regular)

        let placeLayer = CATextLayer()
        placeLayer.string = "📍 \(placeName)"
        placeLayer.font = prostoFont
        placeLayer.fontSize = 80
        placeLayer.foregroundColor = UIColor(red: 1, green: 0.42, blue: 0.21, alpha: 1).cgColor
        placeLayer.alignmentMode = .center
        placeLayer.contentsScale = UIScreen.main.scale
        placeLayer.frame = CGRect(x: 60, y: cY - 100, width: W - 120, height: 100)
        container.addSublayer(placeLayer)

        let dateLayer = CATextLayer()
        dateLayer.string = dateStr
        dateLayer.font = prostoSmallFont
        dateLayer.fontSize = 52
        dateLayer.foregroundColor = UIColor.white.cgColor
        dateLayer.alignmentMode = .center
        dateLayer.contentsScale = UIScreen.main.scale
        dateLayer.frame = CGRect(x: 60, y: cY + 10, width: W - 120, height: 65)
        container.addSublayer(dateLayer)

        // CoreAnimation 타임라인 기준 애니메이션 (beginTime = composition 시간)
        // 텍스트는 클립 시작 후 2.5초만 표시, fade in 0.4s / fade out 0.4s
        let showDuration = min(2.5, clipDuration)
        let fadeIn = 0.4
        let fadeOut = 0.4

        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnim.keyTimes = [
            0,
            NSNumber(value: fadeIn / showDuration),
            NSNumber(value: max(0, (showDuration - fadeOut) / showDuration)),
            1,
            1  // 이후 숨김
        ]
        opacityAnim.values = [0, 1, 1, 0, 0]
        opacityAnim.duration = clipDuration
        opacityAnim.beginTime = startSec + 1e-9  // composition 절대 시간
        opacityAnim.isRemovedOnCompletion = false
        opacityAnim.fillMode = .both

        container.opacity = 0
        container.add(opacityAnim, forKey: "textOverlay")

        return container
    }

    // MARK: - 회전 보정 트랜스폼
    /// 클립의 회전 메타(preferredTransform)를 렌더 프레임(renderSize)에 맞게 변환한다.
    /// 카메라는 1920×1080 landscape 버퍼에 순수 회전 메타만 기록하므로(변위 없음),
    /// 회전 후 콘텐츠가 음수 좌표로 갈 수 있다 → 바운딩 박스를 원점으로 되돌린 뒤
    /// aspect-fit 스케일 + 중앙 정렬을 적용해 세로·가로 모두 바로 서고 프레임에 꽉 차게 한다.
    private static func renderTransform(preferredTransform: CGAffineTransform,
                                        naturalSize: CGSize,
                                        renderSize: CGSize) -> CGAffineTransform {
        // 회전 적용 후의 실제 바운딩 박스 (음수 origin 가능)
        let box = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(box.width), height: abs(box.height))
        guard displaySize.width > 0, displaySize.height > 0,
              renderSize.width > 0, renderSize.height > 0 else { return preferredTransform }

        // 1) 회전된 콘텐츠를 원점(0,0)으로 이동
        let originShift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        // 2) 렌더 프레임에 aspect-fit
        let scale = min(renderSize.width / displaySize.width,
                        renderSize.height / displaySize.height)
        // 3) 중앙 정렬
        let tx = (renderSize.width - displaySize.width * scale) / 2
        let ty = (renderSize.height - displaySize.height * scale) / 2

        return preferredTransform
            .concatenating(originShift)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    // MARK: - Helpers
    private static func fmt(_ date: Date) -> String {
        let f = DateFormatter()
        // 숫자 포맷은 그레고리력·POSIX 로케일로 고정한다. 기기 달력이 불교력/일본력이면
        // "2569.07.11"처럼 엉뚱한 연도가 자막에 박힌다.
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy.MM.dd  HH:mm"
        return f.string(from: date)
    }

    private func creationDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
    }

    // 서버 업로드(VlogServerService)에서도 동일 경로를 쓰므로 static 공유
    static func clipURL(place: Place, sessionId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = place.clipFileName ?? {
            let safeName = place.placeName
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            return "\(place.order)_\(safeName).mp4"
        }()
        return docs.appendingPathComponent("Tteona/Sessions/\(sessionId)/\(name)")
    }
}

enum VlogError: LocalizedError {
    case noClips, noVideoTrack, writeFailed
    var errorDescription: String? {
        switch self {
        case .noClips: return L("vlog.error.noClips")
        case .noVideoTrack: return L("vlog.error.noVideoTrack")
        case .writeFailed: return L("vlog.error.writeFailed")
        }
    }
}
