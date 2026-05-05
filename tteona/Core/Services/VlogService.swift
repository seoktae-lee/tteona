import AVFoundation
import UIKit
import Photos

class VlogService {
    // MARK: - Public Entry Point
    func generateVlog(course: Course, sessionId: String) async throws -> URL {
        var segments: [AVAsset] = []

        for place in course.places.sorted(by: { $0.order < $1.order }) {
            // 1) 지도 스크린샷 → 1.5초 정지 영상
            if let mapImage = await captureMapSnapshot(for: place) {
                let stillAsset = try await makeStillVideoAsset(from: mapImage, duration: 1.5)
                segments.append(stillAsset)
            }

            // 2) 촬영 영상 (FileManager에서 로드)
            let clipURL = localClipURL(place: place, sessionId: sessionId)
            if FileManager.default.fileExists(atPath: clipURL.path) {
                let clipAsset = AVURLAsset(url: clipURL)
                segments.append(clipAsset)
            }
        }

        guard !segments.isEmpty else { throw VlogError.noSegments }

        let output = try await mergeSegments(segments, course: course)
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

    // MARK: - Map Snapshot
    private func captureMapSnapshot(for place: Place) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            options.size = CGSize(width: 1080, height: 1920)
            options.mapType = .standard

            let snapshotter = MKMapSnapshotter(options: options)
            snapshotter.start { snapshot, _ in
                guard let snapshot else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = UIGraphicsImageRenderer(size: options.size).image { ctx in
                    snapshot.image.draw(in: CGRect(origin: .zero, size: options.size))

                    // 핀 아이콘 그리기
                    let pinPoint = snapshot.point(for: place.coordinate)
                    let pinSize = CGSize(width: 40, height: 40)
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
    private func makeStillVideoAsset(from image: UIImage, duration: Double) async throws -> AVAsset {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_still.mp4")

        guard let cgImage = image.cgImage else { throw VlogError.imageConversionFailed }

        let writer = try AVAssetWriter(url: tempURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920
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
            if let buffer = pixelBuffer(from: cgImage, size: CGSize(width: 1080, height: 1920)) {
                adaptor.append(buffer, withPresentationTime: time)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        return AVURLAsset(url: tempURL)
    }

    // MARK: - Merge + Subtitle
    private func mergeSegments(_ assets: [AVAsset], course: Course) async throws -> URL {
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var currentTime = CMTime.zero

        for asset in assets {
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)

            if let srcVideo = try? await asset.loadTracks(withMediaType: .video).first {
                try? videoTrack?.insertTimeRange(range, of: srcVideo, at: currentTime)
            }
            if let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack?.insertTimeRange(range, of: srcAudio, at: currentTime)
            }
            currentTime = CMTimeAdd(currentTime, duration)
        }

        // 자막 레이어 (장소 이름)
        let videoComposition = try await buildVideoComposition(
            for: composition,
            course: course,
            assets: assets
        )

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
            throw VlogError.exportFailed
        }
    }

    private func buildVideoComposition(
        for composition: AVComposition,
        course: Course,
        assets: [AVAsset]
    ) async throws -> AVVideoComposition {
        let size = CGSize(width: 1080, height: 1920)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        guard let videoTrack = composition.tracks(withMediaType: .video).first else {
            throw VlogError.exportFailed
        }

        let instruction = AVMutableVideoCompositionInstruction()
        let duration = try await composition.load(.duration)
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // CALayer 자막 오버레이
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: size)
        videoLayer.frame = CGRect(origin: .zero, size: size)
        parentLayer.addSublayer(videoLayer)

        var time = CMTime.zero
        for (idx, asset) in assets.enumerated() {
            let assetDuration = try await asset.load(.duration)
            // 짝수 인덱스는 지도 스크린샷(장소 이름 표시), 홀수는 실제 클립
            if idx % 2 == 0 {
                let placeIdx = idx / 2
                if placeIdx < course.places.count {
                    let placeName = course.places[placeIdx].placeName
                    addSubtitleLayer(
                        to: parentLayer,
                        text: placeName,
                        startTime: time,
                        duration: CMTime(seconds: 2, preferredTimescale: 600),
                        size: size
                    )
                }
            }
            time = CMTimeAdd(time, assetDuration)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        return videoComposition
    }

    private func addSubtitleLayer(to parent: CALayer, text: String, startTime: CMTime, duration: CMTime, size: CGSize) {
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.font = CTFontCreateWithName("Apple SD Gothic Neo" as CFString, 48, nil)
        textLayer.fontSize = 48
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.alignmentMode = .center
        textLayer.shadowOpacity = 0.8
        textLayer.shadowRadius = 4

        let layerHeight: CGFloat = 80
        textLayer.frame = CGRect(
            x: 0,
            y: size.height * 0.15,
            width: size.width,
            height: layerHeight
        )
        textLayer.isHidden = true

        let showAnim = CABasicAnimation(keyPath: "hidden")
        showAnim.fromValue = false
        showAnim.toValue = false
        showAnim.beginTime = CMTimeGetSeconds(startTime)
        showAnim.duration = CMTimeGetSeconds(duration)
        showAnim.isRemovedOnCompletion = false
        showAnim.fillMode = .forwards

        textLayer.add(showAnim, forKey: "subtitle_\(text)")
        parent.addSublayer(textLayer)
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

// MARK: - MapKit import for snapshot
import MapKit

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
