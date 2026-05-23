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

        struct SegInfo {
            let placeName: String
            let date: Date
            let startTime: CMTime
            let duration: CMTime
            let size: CGSize
        }
        var segInfos: [SegInfo] = []

        // 출력 크기: 첫 번째 유효 클립 기준 사전 결정
        var outputSize = CGSize(width: 1920, height: 1080)
        for seg in segments {
            guard let vTrack = try? await seg.asset.loadTracks(withMediaType: .video).first,
                  let naturalSize = try? await vTrack.load(.naturalSize),
                  naturalSize.width > 0 else { continue }
            let transform = (try? await vTrack.load(.preferredTransform)) ?? .identity
            let isPortrait = abs(transform.b) == 1 && abs(transform.c) == 1
            outputSize = isPortrait
                ? CGSize(width: naturalSize.height, height: naturalSize.width)
                : naturalSize
            break
        }

        // MARK: 타이틀 카드 (날짜) 맨 앞에 삽입
        var titleURL: URL? = nil
        var cursor = CMTime.zero
        do {
            let url = try await makeTitleCardVideo(date: segments.first?.date ?? Date(), size: outputSize)
            titleURL = url
            let titleAsset = AVURLAsset(url: url)
            let titleDuration = try await titleAsset.load(.duration)
            if let titleTrack = try? await titleAsset.loadTracks(withMediaType: .video).first {
                try compVideoTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: titleDuration),
                    of: titleTrack, at: .zero
                )
                cursor = titleDuration
            }
        } catch {
            print("[Vlog] title card failed: \(error) — skipping")
        }

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

        let totalDuration = cursor

        // MARK: VideoComposition — 페이드 인/아웃 + 텍스트 오버레이
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = outputSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        var instructions: [AVMutableVideoCompositionInstruction] = []

        // 타이틀 카드 구간 instruction (페이드 없이 그대로 표시)
        if cursor != segInfos[0].startTime {
            let titleDuration = segInfos[0].startTime
            let titleInstruction = AVMutableVideoCompositionInstruction()
            titleInstruction.timeRange = CMTimeRange(start: .zero, duration: titleDuration)
            let titleLayerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
            titleInstruction.layerInstructions = [titleLayerInstr]
            instructions.append(titleInstruction)
        }

        // 각 클립에 대한 instruction 생성
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

        // 타이틀 카드 임시 파일 정리
        if let url = titleURL { try? FileManager.default.removeItem(at: url) }

        print("[Vlog] export status=\(exp.status.rawValue) error=\(exp.error?.localizedDescription ?? "none")")
        guard exp.status == .completed else { throw exp.error ?? VlogError.writeFailed }
        return outURL
    }

    // MARK: - 타이틀 카드 영상 생성
    private func makeTitleCardVideo(date: Date, size: CGSize) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("title_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let image = makeTitleCardImage(date: date, size: size)
        guard let cgImage = image.cgImage,
              let pixelBuffer = makePixelBuffer(from: cgImage, size: size) else {
            throw VlogError.writeFailed
        }

        let fps: Int32 = 30
        let totalFrames = Int(fps) * 2 // 2초
        for i in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }

        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        guard writer.status == .completed else { throw VlogError.writeFailed }
        return outURL
    }

    private func makeTitleCardImage(date: Date, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            // 배경: tteOrange #FF6B35
            UIColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1.0).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            // 날짜 텍스트 (중앙)
            let dateStr = Self.koreanDateString(date)
            let dateFont = UIFont(name: "GowunBatang-Regular", size: size.height * 0.1)
                ?? UIFont.systemFont(ofSize: size.height * 0.1, weight: .bold)
            let dateAttrs: [NSAttributedString.Key: Any] = [.font: dateFont, .foregroundColor: UIColor.white]
            let dateSize = (dateStr as NSString).size(withAttributes: dateAttrs)
            (dateStr as NSString).draw(
                at: CGPoint(x: (size.width - dateSize.width) / 2, y: (size.height - dateSize.height) / 2),
                withAttributes: dateAttrs
            )

            // tteona (중앙 하단)
            let tteonaFont = UIFont(name: "GowunBatang-Regular", size: size.height * 0.045)
                ?? UIFont.systemFont(ofSize: size.height * 0.045)
            let tteonaAttrs: [NSAttributedString.Key: Any] = [
                .font: tteonaFont,
                .foregroundColor: UIColor.white.withAlphaComponent(0.75)
            ]
            let tteonaSize = ("tteona" as NSString).size(withAttributes: tteonaAttrs)
            ("tteona" as NSString).draw(
                at: CGPoint(x: (size.width - tteonaSize.width) / 2, y: size.height * 0.80),
                withAttributes: tteonaAttrs
            )
        }
    }

    private func makePixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_32ARGB, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return pb
    }

    private static func koreanDateString(_ date: Date) -> String {
        let cal = Calendar.current
        return "\(cal.component(.year, from: date))년 \(cal.component(.month, from: date))월 \(cal.component(.day, from: date))일"
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
        case .noClips: return "촬영된 영상이 없습니다."
        case .noVideoTrack: return "영상 트랙을 읽을 수 없습니다."
        case .writeFailed: return "영상 생성에 실패했습니다."
        }
    }
}
