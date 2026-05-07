import AVFoundation
import UIKit
import Photos

class VlogService {

    // MARK: - Public
    func generateVlog(course: Course, sessionId: String,
                      onProgress: @escaping (Double) -> Void) async throws -> URL {
        let places = course.places.sorted { $0.order < $1.order }

        var segments: [(asset: AVURLAsset, placeName: String, date: Date)] = []
        for place in places {
            let url = clipURL(place: place, sessionId: sessionId)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("[Vlog] skip \(place.placeName) — file not found")
                continue
            }
            segments.append((AVURLAsset(url: url), place.placeName, creationDate(of: url)))
            print("[Vlog] found clip: \(url.lastPathComponent)")
        }
        guard !segments.isEmpty else { throw VlogError.noClips }

        await MainActor.run { onProgress(0.1) }

        let outURL = try await buildComposition(segments: segments, onProgress: onProgress)

        await MainActor.run { onProgress(1.0) }
        print("[Vlog] done: \(outURL.lastPathComponent)")
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

        // 각 세그먼트 정보 (타임라인 위치 기록)
        struct SegInfo {
            let placeName: String
            let date: Date
            let startTime: CMTime
            let duration: CMTime
            let size: CGSize
        }
        var segInfos: [SegInfo] = []
        var cursor = CMTime.zero

        // 클립 순서대로 composition에 삽입
        for (i, seg) in segments.enumerated() {
            let duration = try await seg.asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)

            let videoTracks = try await seg.asset.loadTracks(withMediaType: .video)
            guard let vTrack = videoTracks.first else {
                print("[Vlog] skip \(seg.placeName) — no video track")
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
                size: displaySize
            ))
            cursor = CMTimeAdd(cursor, duration)

            await MainActor.run { onProgress(0.1 + 0.4 * Double(i + 1) / Double(segments.count)) }
        }

        guard !segInfos.isEmpty else { throw VlogError.writeFailed }

        // 출력 크기: 첫 클립 기준 (모두 1920×1080 landscape)
        let outputSize = segInfos[0].size.width > 0 ? segInfos[0].size : CGSize(width: 1920, height: 1080)
        let totalDuration = cursor

        // MARK: VideoComposition — 페이드 인/아웃 + 텍스트 오버레이
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = outputSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        // 각 클립에 대한 instruction 생성
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for (i, info) in segInfos.enumerated() {
            let clipStart = info.startTime
            let clipDuration = info.duration
            let clipEnd = CMTimeAdd(clipStart, clipDuration)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: clipStart, duration: clipDuration)

            let layerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)

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

        for info in segInfos {
            let startSec = CMTimeGetSeconds(info.startTime)
            let durSec = CMTimeGetSeconds(info.duration)
            let totalSec = CMTimeGetSeconds(totalDuration)

            // 배경 밴드 레이어
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

        print("[Vlog] export status=\(exp.status.rawValue) error=\(exp.error?.localizedDescription ?? "none")")
        guard exp.status == .completed else { throw exp.error ?? VlogError.writeFailed }
        return outURL
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

        let prostoFont = UIFont(name: "Jua-Regular", size: 80)
            ?? UIFont.systemFont(ofSize: 80, weight: .bold)
        let prostoSmallFont = UIFont(name: "Jua-Regular", size: 52)
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

    // MARK: - Helpers
    private static func fmt(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd  HH:mm"
        return f.string(from: date)
    }

    private func creationDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
    }

    private func clipURL(place: Place, sessionId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = "\(place.order)_\(place.placeName.replacingOccurrences(of: " ", with: "_")).mp4"
        return docs.appendingPathComponent("Tteona/Sessions/\(sessionId)/\(name)")
    }
}

enum VlogError: LocalizedError {
    case noClips, noVideoTrack, writeFailed
    var errorDescription: String? {
        switch self {
        case .noClips: return "촬영된 영상이 없습니다."
        case .noVideoTrack: return "영상 트랙을 읽을 수 없습니다."
        case .writeFailed: return "영상 생성에 실패했습니다."
        }
    }
}
