import Metal
import ShadeCore
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

    /// JPEG sized for the Claude API: long edge <= 1568 px keeps tokens, latency and upload size reasonable.
    static func jpegForClaude(_ image: UIImage) throws -> Data {
        guard let data = resized(image, maxDimension: 1568).jpegData(compressionQuality: 0.85) else {
            throw ShadeError(.generationInvalidInput, "One of the images couldn't be converted for upload.")
        }
        return data
    }

    /// A small RGBA bitmap for the on-device style analyzer.
    static func analysisBitmap(_ image: UIImage) throws -> RGBAImage {
        let size = StyleAnalyzer.analysisSize
        guard let cg = normalizedCGImage(image, maxDimension: 1024),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ShadeError(.generationInvalidInput, "That image couldn't be read.")
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let raw = ctx.data else { throw ShadeError(.generationInvalidInput, "That image couldn't be read.") }
        let buffer = UnsafeBufferPointer(start: raw.bindMemory(to: UInt8.self, capacity: size * size * 4), count: size * size * 4)
        return try RGBAImage(width: size, height: size, bytes: Array(buffer))
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
