import AVFoundation
import UIKit
import Photos
import MapKit

class VlogService {

    // 촬영 영상과 동일한 사이즈 (CameraService가 1920×1080으로 기록)
    private let renderSize = CGSize(width: 1920, height: 1080)

    // MARK: - Public Entry Point
    func generateVlog(
        course: Course,
        sessionId: String,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let size = renderSize
        let sortedPlaces = course.places.sorted(by: { $0.order < $1.order })

        // 각 장소별로 (메모 클립?, 영상 클립) 수집
        var allClipURLs: [URL] = []
        var tempURLs: [URL] = []

        for (i, place) in sortedPlaces.enumerated() {
            let videoURL = localClipURL(place: place, sessionId: sessionId)
            guard FileManager.default.fileExists(atPath: videoURL.path) else { continue }

            // 메모가 있으면 텍스트 카드 클립 먼저 삽입 (1.5초)
            if let memo = loadMemo(place: place, sessionId: sessionId) {
                let memoImage = await renderMemoImage(placeName: place.placeName, memo: memo, size: size)
                let memoClip = try await makeStillClip(image: memoImage, duration: 1.5, size: size)
                allClipURLs.append(memoClip)
                tempURLs.append(memoClip)
            }

            allClipURLs.append(videoURL)
            onProgress(0.1 + 0.8 * Double(i + 1) / Double(sortedPlaces.count))
        }

        guard !allClipURLs.isEmpty else { throw VlogError.noSegments }

        onProgress(0.92)
        let output = try await mergeClips(allClipURLs, size: size)
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }

        let finalSize = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        print("[generateVlog] status=completed size=\(finalSize)")
        onProgress(1.0)
        return output
    }

    // MARK: - Save / Cleanup
    func saveToPhotoLibrary(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    func deleteLocalClips(sessionId: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("Tteona/Sessions/\(sessionId)"))
    }

    // MARK: - 메모 텍스트 카드 이미지 (UIGraphicsImageRenderer — 완전히 안전)
    @MainActor
    private func renderMemoImage(placeName: String, memo: String, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext

            // 배경: 따뜻한 크림색
            UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))

            let cx = size.width / 2
            let cy = size.height / 2
            let para = NSMutableParagraphStyle()
            para.alignment = .center

            // 장소명
            let placeFont = UIFont(name: "Noteworthy-Bold", size: 52) ?? UIFont.systemFont(ofSize: 52, weight: .bold)
            let placeAttrs: [NSAttributedString.Key: Any] = [
                .font: placeFont,
                .foregroundColor: UIColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1),
                .paragraphStyle: para
            ]
            placeName.draw(in: CGRect(x: 60, y: cy - 200, width: size.width - 120, height: 80),
                           withAttributes: placeAttrs)

            // 구분선
            UIColor.white.withAlphaComponent(0.2).setStroke()
            let line = UIBezierPath(); line.lineWidth = 2
            line.move(to: CGPoint(x: cx - 180, y: cy - 100))
            line.addLine(to: CGPoint(x: cx + 180, y: cy - 100))
            line.stroke()

            // 메모 텍스트
            let memoFont = UIFont(name: "MarkerFelt-Thin", size: 58) ?? UIFont.systemFont(ofSize: 58)
            let memoAttrs: [NSAttributedString.Key: Any] = [
                .font: memoFont,
                .foregroundColor: UIColor.white,
                .paragraphStyle: para
            ]
            memo.draw(in: CGRect(x: 60, y: cy - 60, width: size.width - 120, height: 240),
                      withAttributes: memoAttrs)
        }
    }

    // MARK: - 클립 이어붙이기 (videoComposition 없이 Passthrough — 가장 단순하고 확실)
    private func mergeClips(_ urls: [URL], size: CGSize) async throws -> URL {
        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VlogError.exportFailed
        }
        var cursor = CMTime.zero

        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let v = try? await asset.loadTracks(withMediaType: .video).first {
                try? vTrack.insertTimeRange(range, of: v, at: cursor)
            }
            if let a = try? await asset.loadTracks(withMediaType: .audio).first {
                try? aTrack.insertTimeRange(range, of: a, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tteona_vlog_\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw VlogError.exportFailed
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        await exporter.export()

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        print("[mergeClips] status=\(exporter.status.rawValue) size=\(fileSize) error=\(String(describing: exporter.error))")
        guard exporter.status == .completed else { throw exporter.error ?? VlogError.exportFailed }
        return outputURL
    }

    // MARK: - 정지 이미지 → 영상 클립
    private func makeStillClip(image: UIImage, duration: Double, size: CGSize) async throws -> URL {
        guard let cgImage = image.cgImage else { throw VlogError.imageConversionFailed }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_still.mp4")
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 30
        let lastFrame = max(1, Int32(duration * Double(fps)) - 1)
        for frameIdx in [Int32(0), lastFrame] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            if let pb = pixelBuffer(from: cgImage, size: size) {
                adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frameIdx), timescale: fps))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return outputURL
    }

    // MARK: - Helpers
    private func loadMemo(place: Place, sessionId: String) -> String? {
        let url = memoFileURL(place: place, sessionId: sessionId)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func localClipURL(place: Place, sessionId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(
            "Tteona/Sessions/\(sessionId)/\(place.order)_\(place.placeName.replacingOccurrences(of: " ", with: "_")).mp4")
    }

    private func memoFileURL(place: Place, sessionId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(
            "Tteona/Sessions/\(sessionId)/\(place.order)_\(place.placeName.replacingOccurrences(of: " ", with: "_"))_memo.txt")
    }

    private func pixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
             kCVPixelBufferWidthKey as String: Int(size.width),
             kCVPixelBufferHeightKey as String: Int(size.height)] as CFDictionary, &buffer)
        guard let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        ctx?.draw(cgImage, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
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
