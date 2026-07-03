import UIKit

// 업로드 전 이미지 축소 — 원본 고화질(수 MB~수십 MB) 대신 적당한 크기로 줄여
// 업로드 용량 한도를 넘지 않게 하고 전송 속도도 높인다. 서버가 다시 리샘플하므로 화질 손실 무의미.
enum ImageUploadHelper {
    static func downscaledJPEG(_ image: UIImage,
                               maxDimension: CGFloat = 1440,
                               quality: CGFloat = 0.8) -> Data? {
        let maxSide = max(image.size.width, image.size.height)
        let target: UIImage
        if maxSide > maxDimension {
            let scale = maxDimension / maxSide
            let newSize = CGSize(width: image.size.width * scale,
                                 height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1  // 픽셀 크기 그대로(레티나 배수 방지)
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            target = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            target = image
        }
        return target.jpegData(compressionQuality: quality)
    }
}
