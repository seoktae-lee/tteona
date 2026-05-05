import AVFoundation
import UIKit
import Photos
import MapKit

class VlogService {

    // MARK: - Public Entry Point
    func generateVlog(
        course: Course,
        sessionId: String,
        orientation: VlogOrientation,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let size = orientation.size
        var segments: [SegmentInfo] = []

        // 날씨 가져오기
        onProgress(0.05)
        let weatherInfo: WeatherInfo
        if let firstPlace = course.places.sorted(by: { $0.order < $1.order }).first {
            weatherInfo = await WeatherService().fetchWeather(
                latitude: firstPlace.latitude,
                longitude: firstPlace.longitude
            )
        } else {
            weatherInfo = WeatherInfo(description: "맑음", emoji: "☀️", temp: 20)
        }

        // 인트로 클립 생성 (날짜 + 날씨)
        onProgress(0.1)
        let introAsset = try await makeIntroAsset(weather: weatherInfo, size: size)
        segments.append(SegmentInfo(asset: introAsset, placeName: nil, isIntro: true))

        let sortedPlaces = course.places.sorted(by: { $0.order < $1.order })
        let total = Double(sortedPlaces.count)

        for (i, place) in sortedPlaces.enumerated() {
            let clipURL = localClipURL(place: place, sessionId: sessionId)
            if FileManager.default.fileExists(atPath: clipURL.path) {
                let clipAsset = AVURLAsset(url: clipURL)
                segments.append(SegmentInfo(asset: clipAsset, placeName: place.placeName, isIntro: false))
            } else if let mapImage = await captureMapSnapshot(for: place, size: size) {
                let stillAsset = try await makeStillVideoAsset(from: mapImage, duration: 2.0, size: size)
                segments.append(SegmentInfo(asset: stillAsset, placeName: place.placeName, isIntro: false))
            }
            onProgress(0.1 + 0.6 * Double(i + 1) / total)
        }

        guard !segments.isEmpty else { throw VlogError.noSegments }

        onProgress(0.75)
        let output = try await mergeSegments(segments, course: course, size: size, onProgress: { p in
            onProgress(0.75 + 0.24 * p)
        })
        onProgress(1.0)
        return output
    }

    // MARK: - Save to Photos
    func saveToPhotoLibrary(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    // MARK: - Cleanup
    func deleteLocalClips(sessionId: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionDir = docs
            .appendingPathComponent("Tteona")
            .appendingPathComponent("Sessions")
            .appendingPathComponent(sessionId)
        try? FileManager.default.removeItem(at: sessionDir)
    }

    // MARK: - Intro Clip
    private func makeIntroAsset(weather: WeatherInfo, size: CGSize) async throws -> AVAsset {
        let image = await renderIntroImage(weather: weather, size: size)
        return try await makeStillVideoAsset(from: image, duration: 3.0, size: size)
    }

    private func renderIntroImage(weather: WeatherInfo, size: CGSize) async -> UIImage {
        await MainActor.run {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                let cgCtx = ctx.cgContext

                // 배경: 크림 단색으로 먼저 채우고 그라디언트 오버레이
                UIColor(red: 0.97, green: 0.93, blue: 0.83, alpha: 1).setFill()
                cgCtx.fill(CGRect(origin: .zero, size: size))

                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let colors: [CGFloat] = [
                    0.99, 0.96, 0.89, 1.0,   // top: 연크림
                    0.94, 0.87, 0.72, 1.0    // bottom: 따뜻한 베이지
                ]
                if let gradient = CGGradient(colorSpace: colorSpace,
                                             colorComponents: colors,
                                             locations: nil,
                                             count: 2) {
                    cgCtx.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: size.width / 2, y: 0),
                        end: CGPoint(x: size.width / 2, y: size.height),
                        options: []
                    )
                }

                let isPortrait = size.height > size.width
                let centerX = size.width / 2
                let centerY = size.height / 2

                // 날짜 텍스트 (Noteworthy-Bold 손글씨체)
                let dateFormatter = DateFormatter()
                dateFormatter.locale = Locale(identifier: "ko_KR")
                dateFormatter.dateFormat = "yyyy년 M월 d일"
                let dateString = dateFormatter.string(from: Date())

                let dateFontSize: CGFloat = isPortrait ? 80 : 64
                let dateParagraph = NSMutableParagraphStyle()
                dateParagraph.alignment = .center
                let dateFont = UIFont(name: "Noteworthy-Bold", size: dateFontSize)
                    ?? UIFont.systemFont(ofSize: dateFontSize, weight: .bold)
                let dateAttrs: [NSAttributedString.Key: Any] = [
                    .font: dateFont,
                    .foregroundColor: UIColor(red: 0.25, green: 0.18, blue: 0.08, alpha: 1),
                    .paragraphStyle: dateParagraph
                ]
                let dateRect = CGRect(
                    x: 60, y: centerY - (isPortrait ? 140 : 100),
                    width: size.width - 120, height: dateFontSize * 1.4
                )
                dateString.draw(in: dateRect, withAttributes: dateAttrs)

                // 날씨 이모지 + 설명
                let weatherFontSize: CGFloat = isPortrait ? 68 : 52
                let weatherParagraph = NSMutableParagraphStyle()
                weatherParagraph.alignment = .center
                let weatherFont = UIFont(name: "Noteworthy-Bold", size: weatherFontSize)
                    ?? UIFont.systemFont(ofSize: weatherFontSize, weight: .medium)
                let weatherString = "\(weather.emoji) \(weather.description)  \(Int(weather.temp))°"
                let weatherAttrs: [NSAttributedString.Key: Any] = [
                    .font: weatherFont,
                    .foregroundColor: UIColor(red: 0.50, green: 0.35, blue: 0.10, alpha: 1),
                    .paragraphStyle: weatherParagraph
                ]
                let weatherRect = CGRect(
                    x: 60, y: centerY + (isPortrait ? 20 : 10),
                    width: size.width - 120, height: weatherFontSize * 1.6
                )
                weatherString.draw(in: weatherRect, withAttributes: weatherAttrs)

                // 아래 작은 장식선
                let lineY = centerY + (isPortrait ? -20.0 : -10.0)
                UIColor(red: 0.85, green: 0.65, blue: 0.30, alpha: 0.6).setStroke()
                let linePath = UIBezierPath()
                linePath.lineWidth = isPortrait ? 3 : 2
                linePath.move(to: CGPoint(x: centerX - (isPortrait ? 200 : 160), y: lineY))
                linePath.addLine(to: CGPoint(x: centerX + (isPortrait ? 200 : 160), y: lineY))
                linePath.stroke()
            }
        }
    }

    // MARK: - Map Snapshot
    private func captureMapSnapshot(for place: Place, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            options.size = size
            options.mapType = .standard

            let snapshotter = MKMapSnapshotter(options: options)
            snapshotter.start { snapshot, _ in
                guard let snapshot else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = UIGraphicsImageRenderer(size: size).image { ctx in
                    snapshot.image.draw(in: CGRect(origin: .zero, size: size))
                    let pinPoint = snapshot.point(for: place.coordinate)
                    let pinSize = CGSize(width: 44, height: 44)
                    let pinRect = CGRect(
                        x: pinPoint.x - pinSize.width / 2,
                        y: pinPoint.y - pinSize.height / 2,
                        width: pinSize.width,
                        height: pinSize.height
                    )
                    UIColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1).setFill()
                    UIBezierPath(ovalIn: pinRect).fill()
                }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Still Image → Video
    private func makeStillVideoAsset(from image: UIImage, duration: Double, size: CGSize) async throws -> AVAsset {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_still.mp4")

        guard let cgImage = image.cgImage else { throw VlogError.imageConversionFailed }

        let writer = try AVAssetWriter(url: tempURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
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

        let fps: Int32 = 30
        let totalFrames = Int(duration * Double(fps))

        for frameIdx in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let time = CMTime(value: CMTimeValue(frameIdx), timescale: fps)
            if let buffer = pixelBuffer(from: cgImage, size: size) {
                adaptor.append(buffer, withPresentationTime: time)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        return AVURLAsset(url: tempURL)
    }

    // MARK: - Merge + Overlays
    private func mergeSegments(
        _ segments: [SegmentInfo],
        course: Course,
        size: CGSize,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var currentTime = CMTime.zero
        var segmentTimings: [(start: CMTime, duration: CMTime, info: SegmentInfo)] = []

        for segment in segments {
            let duration = try await segment.asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)

            if let srcVideo = try? await segment.asset.loadTracks(withMediaType: .video).first {
                try? videoTrack?.insertTimeRange(range, of: srcVideo, at: currentTime)
            }
            if let srcAudio = try? await segment.asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack?.insertTimeRange(range, of: srcAudio, at: currentTime)
            }
            segmentTimings.append((start: currentTime, duration: duration, info: segment))
            currentTime = CMTimeAdd(currentTime, duration)
        }

        onProgress(0.3)

        let videoComposition = try await buildVideoComposition(
            for: composition,
            segmentTimings: segmentTimings,
            size: size
        )

        onProgress(0.6)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tteona_vlog_\(UUID().uuidString).mp4")

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else { throw VlogError.exportFailed }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComposition

        await exporter.export()
        if exporter.status == .completed {
            return outputURL
        } else {
            throw exporter.error ?? VlogError.exportFailed
        }
    }

    private func buildVideoComposition(
        for composition: AVComposition,
        segmentTimings: [(start: CMTime, duration: CMTime, info: SegmentInfo)],
        size: CGSize
    ) async throws -> AVVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        guard let compositionVideoTrack = composition.tracks(withMediaType: .video).first else {
            throw VlogError.exportFailed
        }

        // 각 세그먼트마다 개별 instruction 생성 → 각 클립의 preferredTransform 적용
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for timing in segmentTimings {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: timing.start, duration: timing.duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)

            // 원본 클립의 naturalSize + preferredTransform으로 정확한 렌더 transform 계산
            if let originalTracks = try? await timing.info.asset.loadTracks(withMediaType: .video),
               let srcTrack = originalTracks.first {
                let srcTransform = try await srcTrack.load(.preferredTransform)
                let srcSize = try await srcTrack.load(.naturalSize)
                let transform = videoFillTransform(
                    naturalSize: srcSize,
                    preferredTransform: srcTransform,
                    renderSize: size
                )
                // setTransform의 at: 은 composition 내 절대 시간이므로 timing.start 사용
                layerInstruction.setTransform(transform, at: timing.start)
            }

            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)
        }
        videoComposition.instructions = instructions

        // CALayer 오버레이
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: size)
        videoLayer.frame = CGRect(origin: .zero, size: size)
        parentLayer.addSublayer(videoLayer)

        for timing in segmentTimings {
            let startSec = CMTimeGetSeconds(timing.start)
            let durSec = CMTimeGetSeconds(timing.duration)

            if timing.info.isIntro {
                addFadeInLayer(to: parentLayer, startTime: startSec, duration: durSec, size: size)
            } else if let placeName = timing.info.placeName {
                addZoomInTransition(to: parentLayer, startTime: startSec, size: size)
                addPlaceNameLayer(to: parentLayer, text: placeName, startTime: startSec, duration: durSec, size: size)
            }
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        return videoComposition
    }

    /// iPhone 촬영 영상의 preferredTransform + naturalSize를 renderSize에 aspect-fill로 맞추는 transform 계산
    private func videoFillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        // preferredTransform 적용 후 실제 표시 크기 (회전 여부 판단)
        let isRotated90 = (preferredTransform.b != 0 || preferredTransform.c != 0)
        let displaySize: CGSize = isRotated90
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize

        // 표시 크기를 렌더 사이즈에 aspect-fill로 채우는 스케일
        let scaleX = renderSize.width  / displaySize.width
        let scaleY = renderSize.height / displaySize.height
        let scale  = max(scaleX, scaleY)

        // 스케일 후 센터 정렬 translation
        let scaledW = displaySize.width  * scale
        let scaledH = displaySize.height * scale
        let offsetX = (renderSize.width  - scaledW) / 2
        let offsetY = (renderSize.height - scaledH) / 2

        // iPhone 4가지 방향별 정확한 rotation translation 보정
        // (AVFoundation 좌표계: origin이 좌하단)
        var baseTransform = preferredTransform
        let a = preferredTransform.a
        let b = preferredTransform.b
        let d = preferredTransform.d

        if b == 1 && a == 0 {
            // 90° portrait (세로 촬영)
            baseTransform.tx = 0
            baseTransform.ty = naturalSize.width
        } else if b == -1 && a == 0 {
            // 270° (세로 촬영 upside-down)
            baseTransform.tx = naturalSize.height
            baseTransform.ty = 0
        } else if a == 1 && b == 0 {
            // 0° landscape (가로 촬영 홈버튼 오른쪽)
            baseTransform.tx = 0
            baseTransform.ty = 0
        } else if a == -1 && b == 0 {
            // 180° landscape (가로 촬영 홈버튼 왼쪽)
            baseTransform.tx = naturalSize.width
            baseTransform.ty = naturalSize.height
        } else {
            // 실수값 transform (드문 케이스) — tx/ty 그대로
            _ = d
        }

        let scaleT     = CGAffineTransform(scaleX: scale, y: scale)
        let translateT = CGAffineTransform(translationX: offsetX, y: offsetY)
        return baseTransform.concatenating(scaleT).concatenating(translateT)
    }

    // MARK: - CALayer Overlays

    private func addFadeInLayer(to parent: CALayer, startTime: Double, duration: Double, size: CGSize) {
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: size)
        overlay.backgroundColor = UIColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1).cgColor
        overlay.opacity = 0

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 1.0
        fadeIn.toValue = 0.0
        fadeIn.beginTime = startTime
        fadeIn.duration = min(1.0, duration * 0.4)
        fadeIn.isRemovedOnCompletion = false
        fadeIn.fillMode = .forwards
        overlay.add(fadeIn, forKey: "fadeIn")
        parent.addSublayer(overlay)
    }

    private func addZoomInTransition(to parent: CALayer, startTime: Double, size: CGSize) {
        // 세그먼트 시작 시점에 scale 1.3 → 1.0 으로 줌인 (빨려드는 효과)
        let transitionDuration = 0.8
        let zoomLayer = CALayer()
        zoomLayer.frame = CGRect(origin: .zero, size: size)
        zoomLayer.backgroundColor = UIColor.clear.cgColor
        zoomLayer.opacity = 0

        // 어두운 비네트 오버레이를 잠깐 보여줘서 컷 감추기
        let vignetteLayer = CALayer()
        vignetteLayer.frame = CGRect(origin: .zero, size: size)
        vignetteLayer.backgroundColor = UIColor.black.cgColor
        vignetteLayer.opacity = 0

        let flashAnim = CAKeyframeAnimation(keyPath: "opacity")
        flashAnim.values = [0.0, 0.45, 0.0]
        flashAnim.keyTimes = [0, 0.15, 1.0]
        flashAnim.beginTime = startTime
        flashAnim.duration = transitionDuration
        flashAnim.isRemovedOnCompletion = false
        flashAnim.fillMode = .forwards
        vignetteLayer.add(flashAnim, forKey: "flash")
        parent.addSublayer(vignetteLayer)
        _ = zoomLayer
    }

    private func addPlaceNameLayer(to parent: CALayer, text: String, startTime: Double, duration: Double, size: CGSize) {
        let isPortrait = size.height > size.width
        let fontSize: CGFloat = isPortrait ? 52 : 42

        // 배경 바
        let barHeight: CGFloat = isPortrait ? 90 : 72
        let barY = size.height * (isPortrait ? 0.82 : 0.80)
        let barLayer = CALayer()
        barLayer.frame = CGRect(x: 0, y: barY, width: size.width, height: barHeight)
        barLayer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
        barLayer.opacity = 0
        addAppearAnimation(to: barLayer, startTime: startTime, duration: duration)
        parent.addSublayer(barLayer)

        // 장소명 텍스트
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.font = CTFontCreateWithName("Noteworthy-Bold" as CFString, fontSize, nil)
        textLayer.fontSize = fontSize
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.alignmentMode = .center
        textLayer.shadowOpacity = 0.6
        textLayer.shadowRadius = 3
        textLayer.contentsScale = 3.0
        textLayer.frame = CGRect(
            x: 40,
            y: barY + (barHeight - fontSize * 1.2) / 2,
            width: size.width - 80,
            height: fontSize * 1.2
        )
        textLayer.opacity = 0
        addAppearAnimation(to: textLayer, startTime: startTime, duration: duration)
        parent.addSublayer(textLayer)
    }

    private func addAppearAnimation(to layer: CALayer, startTime: Double, duration: Double) {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.0, 1.0, 1.0, 0.0]
        let fadeOut = min(startTime + duration - 0.4, startTime + duration)
        let relFadeOut = (fadeOut - startTime) / duration
        anim.keyTimes = [0, NSNumber(value: min(0.15, 0.3)), NSNumber(value: relFadeOut), 1.0]
        anim.beginTime = startTime
        anim.duration = duration
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        layer.add(anim, forKey: "appear")
    }

    // MARK: - Helpers
    private func localClipURL(place: Place, sessionId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "\(place.order)_\(place.placeName.replacingOccurrences(of: " ", with: "_")).mp4"
        return docs
            .appendingPathComponent("Tteona")
            .appendingPathComponent("Sessions")
            .appendingPathComponent(sessionId)
            .appendingPathComponent(filename)
    }

    private func pixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &buffer)
        guard let pb = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        ctx?.draw(cgImage, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}

// MARK: - Supporting Types
private struct SegmentInfo {
    let asset: AVAsset
    let placeName: String?
    let isIntro: Bool
}

enum VlogError: LocalizedError {
    case noSegments
    case imageConversionFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noSegments: return "생성할 영상 세그먼트가 없습니다."
        case .imageConversionFailed: return "이미지 변환에 실패했습니다."
        case .exportFailed: return "영상 내보내기에 실패했습니다."
        }
    }
}
