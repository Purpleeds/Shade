import Metal
import Photos
import UIKit

enum ImageUtils {
    /// Redraws an image upright (applying EXIF orientation) and no larger than `maxDimension`.
    static func normalizedCGImage(_ image: UIImage, maxDimension: CGFloat) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.cgImage
    }

    static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        guard let cg = normalizedCGImage(image, maxDimension: maxDimension) else { return image }
        return UIImage(cgImage: cg)
    }

    /// JPEG data sized for the Claude API (long edge <= 1568 px keeps tokens and latency reasonable).
    static func jpegForClaude(_ image: UIImage) -> Data? {
        resized(image, maxDimension: 1568).jpegData(compressionQuality: 0.85)
    }

    /// Reads a shared-storage `.bgra8Unorm` texture into a UIImage.
    static func image(fromBGRA texture: MTLTexture) -> UIImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { ptr in
            texture.getBytes(ptr.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                               space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "Shade isn't allowed to add to your photo library. Enable it in Settings → Shade → Photos." }
    }

    static func save(image: UIImage) async throws {
        try await save { _ = PHAssetChangeRequest.creationRequestForAsset(from: image) }
    }

    static func save(videoAt url: URL) async throws {
        try await save { _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
        try? FileManager.default.removeItem(at: url)
    }

    private static func save(_ change: @escaping @Sendable () -> Void) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges(change)
    }
}
