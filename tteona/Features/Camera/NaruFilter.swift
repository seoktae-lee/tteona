import CoreImage
import Metal
import MetalKit
import UIKit

// MARK: - 나루 무드 필터
/// 촬영 실시간 필터 프리셋. 프리뷰(MTKView)와 기록(AVAssetWriter 픽셀버퍼) 양쪽에
/// 동일한 CIFilter 체인을 적용해 WYSIWYG를 보장한다.
enum NaruFilter: Int, CaseIterable {
    case none = 0   // 기본 (필터 없음)
    case cozy       // 포근 — 따뜻한 톤 + 약한 비네트
    case film       // 필름 — 빛바랜 톤커브 + 채도 다운 + 비네트
    case fresh      // 청량 — 차가운 톤 + 채도 업

    var titleKey: String {
        switch self {
        case .none:  return "camera.filter.none"
        case .cozy:  return "camera.filter.cozy"
        case .film:  return "camera.filter.film"
        case .fresh: return "camera.filter.fresh"
        }
    }

    /// 마지막 선택 기억 (앱 재실행에도 유지)
    static var saved: NaruFilter {
        get { NaruFilter(rawValue: UserDefaults.standard.integer(forKey: "naruFilter")) ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "naruFilter") }
    }

    func apply(to image: CIImage) -> CIImage {
        guard self != .none else { return image }
        let extent = image.extent
        var img = image

        switch self {
        case .none:
            break

        case .cozy:
            // 따뜻한 화이트밸런스 (target > neutral → 오렌지 쪽으로)
            img = Self.temperature(img, target: CIVector(x: 7300, y: 10))
            img = Self.colorControls(img, saturation: 1.08, brightness: 0.015, contrast: 1.0)
            img = Self.vignette(img, intensity: 0.35, radius: 1.8)

        case .film:
            // 블랙 살짝 들어올린 페이드 톤커브
            if let f = CIFilter(name: "CIToneCurve") {
                f.setValue(img, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 0.0,  y: 0.06), forKey: "inputPoint0")
                f.setValue(CIVector(x: 0.25, y: 0.24), forKey: "inputPoint1")
                f.setValue(CIVector(x: 0.5,  y: 0.50), forKey: "inputPoint2")
                f.setValue(CIVector(x: 0.75, y: 0.78), forKey: "inputPoint3")
                f.setValue(CIVector(x: 1.0,  y: 0.96), forKey: "inputPoint4")
                img = f.outputImage ?? img
            }
            img = Self.colorControls(img, saturation: 0.85, brightness: 0, contrast: 1.06)
            img = Self.vignette(img, intensity: 0.6, radius: 1.6)

        case .fresh:
            // 차가운 화이트밸런스 (target < neutral → 블루 쪽으로)
            img = Self.temperature(img, target: CIVector(x: 5600, y: -10))
            img = Self.colorControls(img, saturation: 1.12, brightness: 0.01, contrast: 1.04)
        }
        // 필터 체인이 extent를 바꾸지 않도록 고정 (기록 픽셀버퍼 렌더 안전)
        return img.cropped(to: extent)
    }

    // MARK: 체인 헬퍼
    private static func temperature(_ image: CIImage, target: CIVector) -> CIImage {
        guard let f = CIFilter(name: "CITemperatureAndTint") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
        f.setValue(target, forKey: "inputTargetNeutral")
        return f.outputImage ?? image
    }

    private static func colorControls(_ image: CIImage, saturation: CGFloat, brightness: CGFloat, contrast: CGFloat) -> CIImage {
        guard let f = CIFilter(name: "CIColorControls") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(saturation, forKey: kCIInputSaturationKey)
        f.setValue(brightness, forKey: kCIInputBrightnessKey)
        f.setValue(contrast, forKey: kCIInputContrastKey)
        return f.outputImage ?? image
    }

    private static func vignette(_ image: CIImage, intensity: CGFloat, radius: CGFloat) -> CIImage {
        guard let f = CIFilter(name: "CIVignette") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(intensity, forKey: kCIInputIntensityKey)
        f.setValue(radius, forKey: kCIInputRadiusKey)
        return f.outputImage ?? image
    }
}

// MARK: - 필터 프리뷰 (Metal)
/// 필터 선택 시 AVCaptureVideoPreviewLayer 위에 올라가는 실시간 필터 프리뷰.
/// 기본(필터 없음)일 때는 숨겨져 기존 프리뷰 경로가 그대로 동작한다 — 회귀 리스크 최소화.
final class FilteredPreviewMTKView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    /// 표시할 이미지 — display(image:)로만 갱신
    private var image: CIImage?

    init(frame: CGRect) {
        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: dev)
        if let dev {
            commandQueue = dev.makeCommandQueue()
            ciContext = CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
        }
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        backgroundColor = .black
        isUserInteractionEnabled = false   // 터치(핀치/탭)는 아래 VC 제스처로 통과
    }
    required init(coder: NSCoder) { fatalError() }

    /// 캡처 프레임 표시 — 메인 스레드에서 호출
    func display(image: CIImage) {
        self.image = image
        draw()
    }

    func draw(in view: MTKView) {
        guard let image, let drawable = currentDrawable,
              let ciContext, let queue = commandQueue,
              let buffer = queue.makeCommandBuffer() else { return }
        let dw = CGFloat(drawableSize.width), dh = CGFloat(drawableSize.height)
        guard dw > 0, dh > 0, image.extent.width > 0 else { return }
        // aspect-fill (previewLayer .resizeAspectFill과 동일)
        let scale = max(dw / image.extent.width, dh / image.extent.height)
        var img = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        img = img.transformed(by: CGAffineTransform(
            translationX: (dw - img.extent.width) / 2 - img.extent.minX,
            y: (dh - img.extent.height) / 2 - img.extent.minY
        ))
        ciContext.render(img, to: drawable.texture, commandBuffer: buffer,
                         bounds: CGRect(x: 0, y: 0, width: dw, height: dh), colorSpace: colorSpace)
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
