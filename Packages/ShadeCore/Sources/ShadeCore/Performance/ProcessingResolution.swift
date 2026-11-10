import Foundation

/// A width × height in pixels.
public struct PixelSize: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var megapixels: Double { Double(width * height) / 1_000_000 }
    public var shortSide: Int { min(width, height) }
    public var description: String { "\(width)×\(height)" }
}

/// Which camera stream to ask for. The app maps these to AVCaptureSession presets.
public enum CaptureTier: String, Sendable {
    case hd720, hd1080, uhd4K
}

/// How many megapixels Shade processes. It sets the camera stream, the size every effect runs at,
/// and the size of saved photos and videos. Each step up costs roughly twice the GPU work of the last.
public enum ProcessingResolution: String, CaseIterable, Identifiable, Sendable {
    case p540, p720, p1080, p1440, p2160

    public static let defaultValue: ProcessingResolution = .p1080
    public static let defaultsKey = "processingResolution"

    public var id: String { rawValue }

    /// Pixels on the short side (the width of a portrait frame).
    public var shortSide: Int {
        switch self {
        case .p540: return 540
        case .p720: return 720
        case .p1080: return 1080
        case .p1440: return 1440
        case .p2160: return 2160
        }
    }

    /// Pixels on the long side, for 16:9 camera frames.
    public var longSide: Int { shortSide * 16 / 9 }

    public var megapixels: Double { Double(shortSide * longSide) / 1_000_000 }

    /// e.g. "2.1 MP".
    public var megapixelLabel: String { String(format: "%.1f MP", megapixels) }

    /// e.g. "1080 × 1920".
    public var dimensionsLabel: String { "\(shortSide) × \(longSide)" }

    public var note: String {
        switch self {
        case .p540: return "Smoothest, softest"
        case .p720: return "Smooth on any iPhone"
        case .p1080: return "Sharp, the default"
        case .p1440: return "Very sharp, heavier"
        case .p2160: return "Maximum (4K), can stutter on heavy looks"
        }
    }

    /// The camera stream that delivers at least this many pixels.
    public var captureTier: CaptureTier {
        switch self {
        case .p540, .p720: return .hd720
        case .p1080: return .hd1080
        case .p1440, .p2160: return .uhd4K
        }
    }

    /// The size to process a frame of `input` size at. Keeps the input's aspect ratio; the short side is
    /// this resolution's short side (never upscaling past the input), multiplied by `scale` (Smooth mode).
    /// Dimensions are even (video encoders need that) and at least 64.
    public func processingSize(input: PixelSize, scale: Double = 1) -> PixelSize {
        guard input.width > 0, input.height > 0 else { return PixelSize(width: 64, height: 64) }
        let clampedScale = min(max(scale, 0.1), 1)
        let targetShort = Double(min(shortSide, input.shortSide)) * clampedScale
        let factor = targetShort / Double(input.shortSide)
        func even(_ v: Double) -> Int { max(64, Int((v / 2).rounded()) * 2) }
        return PixelSize(width: even(Double(input.width) * factor), height: even(Double(input.height) * factor))
    }

    /// Falls back to the default for missing or unknown stored values.
    public init(storedValue: String?) {
        self = storedValue.flatMap(ProcessingResolution.init(rawValue:)) ?? .defaultValue
    }
}
