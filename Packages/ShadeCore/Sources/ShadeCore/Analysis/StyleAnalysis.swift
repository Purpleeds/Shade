import Foundation

/// An 8-bit RGBA bitmap, row-major, top row first. The app fills it from a UIImage; tests build it directly.
public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) throws {
        guard width >= 8, height >= 8, bytes.count == width * height * 4 else {
            throw ShadeError(.generationInvalidInput, "That image is too small or damaged to analyze.",
                             detail: "\(width)x\(height), \(bytes.count) bytes")
        }
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

/// Offline "style match": measures a reference image (palette, tone, saturation, grain, edges, vignetting)
/// and builds a recipe from built-in effects. No network or API key needed; less clever than Claude, but instant.
public enum StyleAnalyzer {
    /// The app should downscale images to about this size before analysis.
    public static let analysisSize = 160

    public struct Analysis: Sendable {
        public var palette: [SIMD3<Float>]      // sorted dark -> light
        public var paletteCoverage: Float       // share of pixels close to a palette color (flat-color art scores high)
        public var meanLuma: Float
        public var lumaStd: Float
        public var meanSaturation: Float
        public var warmth: Float                // red-vs-blue balance, -1...1
        public var meanColor: SIMD3<Float>
        public var grain: Float                 // high-frequency noise level
        public var edgeDensity: Float           // share of pixels on strong edges
        public var vignette: Float              // how much darker the corners are than the center
    }

    public static func analyze(_ image: RGBAImage) -> Analysis {
        let width = image.width
        let height = image.height
        let pixels = image.bytes
        let count = width * height

        var colors = [SIMD3<Float>](repeating: .zero, count: count)
        var lumas = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let c = SIMD3<Float>(Float(pixels[i * 4]), Float(pixels[i * 4 + 1]), Float(pixels[i * 4 + 2])) / 255
            colors[i] = c
            lumas[i] = luma(c)
        }
        let n = Float(colors.count)

        var lumaSum: Float = 0
        var colorSum = SIMD3<Float>(0, 0, 0)
        var saturationSum: Float = 0
        for (i, c) in colors.enumerated() {
            lumaSum += lumas[i]
            colorSum += c
            let mx: Float = Swift.max(c.x, Swift.max(c.y, c.z))
            let mn: Float = Swift.min(c.x, Swift.min(c.y, c.z))
            if mx > 0.001 { saturationSum += (mx - mn) / mx }
        }
        let meanLuma: Float = lumaSum / n
        var variance: Float = 0
        for l in lumas { variance += (l - meanLuma) * (l - meanLuma) }
        let lumaStd: Float = (variance / n).squareRoot()
        let meanColor: SIMD3<Float> = colorSum / n
        let meanSaturation: Float = saturationSum / n
        let warmth: Float = Swift.max(-1, Swift.min(1, (meanColor.x - meanColor.z) * 2.5))

        // Grain and edges from the luminance image.
        var residual: Float = 0
        var strongEdges = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let blur = (lumas[i - 1] + lumas[i + 1] + lumas[i - width] + lumas[i + width]) / 4
                residual += abs(lumas[i] - blur)
                let gx = lumas[i + 1] - lumas[i - 1]
                let gy = lumas[i + width] - lumas[i - width]
                if (gx * gx + gy * gy).squareRoot() > 0.25 { strongEdges += 1 }
            }
        }
        let inner = Float((width - 2) * (height - 2))
        let grain = residual / inner
        let edgeDensity = Float(strongEdges) / inner

        // Vignette: corners vs center brightness.
        func regionLuma(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> Float {
            var s: Float = 0
            for y in y0..<(y0 + h) { for x in x0..<(x0 + w) { s += lumas[y * width + x] } }
            return s / Float(w * h)
        }
        let cw = Swift.max(1, width / 8)
        let ch = Swift.max(1, height / 8)
        let cornerA: Float = regionLuma(0, 0, cw, ch) + regionLuma(width - cw, 0, cw, ch)
        let cornerB: Float = regionLuma(0, height - ch, cw, ch) + regionLuma(width - cw, height - ch, cw, ch)
        let corners: Float = (cornerA + cornerB) / 4
        let center = regionLuma(width / 2 - cw, height / 2 - ch, cw * 2, ch * 2)
        let vignette = Swift.max(0, center - corners)

        let (palette, coverage) = kMeans(colors, k: 5)
        return Analysis(palette: palette, paletteCoverage: coverage, meanLuma: meanLuma, lumaStd: lumaStd,
                        meanSaturation: meanSaturation, warmth: warmth, meanColor: meanColor, grain: grain,
                        edgeDensity: edgeDensity, vignette: vignette)
    }

    public static func recipe(from image: RGBAImage, name: String = "Style Match") throws -> ShaderRecipe {
        try RecipeValidator.validate(recipe(from: analyze(image), name: name))
    }

    public static func recipe(from a: Analysis, name: String = "Style Match") -> ShaderRecipe {
        var passes: [ShaderPass] = []

        // Typical phone footage: mean luma ~0.45, std ~0.22, saturation ~0.35.
        let contrast = clamp(a.lumaStd / 0.22, 0.6, 1.8)
        let saturation = clamp(a.meanSaturation / 0.35, 0, 1.8)
        let exposure = clamp(log2(max(a.meanLuma, 0.05) / 0.45), -1.2, 1.2)
        let gray = luma(a.meanColor)
        var tint = gray > 0.01 ? a.meanColor / gray : SIMD3<Float>(1, 1, 1)
        tint = lerp3(SIMD3<Float>(1, 1, 1), tint, SIMD3<Float>(repeating: 0.35))
        tint = tint / max(tint.x, max(tint.y, tint.z))
        passes.append(.builtIn("colorGrade", [
            "exposure": [exposure], "contrast": [contrast], "saturation": [saturation],
            "temperature": [a.warmth * 0.5], "tint": [tint.x, tint.y, tint.z]
        ]))

        let flat = a.paletteCoverage > 0.85 && a.grain < 0.04
        if flat {
            passes.append(.builtIn("posterize", ["levels": [a.meanSaturation > 0.3 ? 5 : 4]]))
        }
        if a.meanSaturation < 0.08 {
            // Essentially monochrome: map onto its own tones.
            let dark = a.palette.first ?? SIMD3<Float>(0, 0, 0)
            let light = a.palette.last ?? SIMD3<Float>(1, 1, 1)
            passes.append(.builtIn("duotone", ["shadows": [dark.x, dark.y, dark.z], "highlights": [light.x, light.y, light.z],
                                               "contrast": [contrast]], mix: 0.8))
        } else {
            var mapped: [String: [Float]] = [:]
            for (i, c) in a.palette.prefix(5).enumerated() { mapped["c\(i)"] = [c.x, c.y, c.z] }
            passes.append(.builtIn("paletteMap", mapped, mix: flat ? 0.75 : 0.45))
        }
        if a.edgeDensity > 0.06 && flat {
            passes.append(.builtIn("edges", ["threshold": [0.35], "thickness": [1.4]]))
        }
        if a.grain > 0.035 && !flat {
            passes.append(.builtIn("grain", ["amount": [clamp(a.grain * 2.2, 0.03, 0.3)], "size": [1.5]]))
        }
        if a.vignette > 0.08 {
            passes.append(.builtIn("vignette", ["strength": [clamp(a.vignette * 3, 0.3, 1)]]))
        }

        return ShaderRecipe(name: name, description: "Matched on-device from a reference image.", author: "On-device analyzer", passes: passes)
    }

    // MARK: Helpers

    private static func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    private static func distanceSquared(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return d.x * d.x + d.y * d.y + d.z * d.z
    }

    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

    private static func lerp3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: SIMD3<Float>) -> SIMD3<Float> { a + (b - a) * t }

    /// Small k-means in RGB. Returns centers sorted by brightness and the share of pixels within 0.1 of a center.
    private static func kMeans(_ colors: [SIMD3<Float>], k: Int) -> ([SIMD3<Float>], Float) {
        let sample = stride(from: 0, to: colors.count, by: 3).map { colors[$0] }
        guard !sample.isEmpty else { return ([], 0) }
        // Seed with luminance quantiles for stable, well-spread starting points.
        let sorted = sample.sorted { luma($0) < luma($1) }
        var centers: [SIMD3<Float>] = []
        for j in 0..<k {
            let index: Int = Swift.min(sorted.count - 1, (j * 2 + 1) * sorted.count / (2 * k))
            centers.append(sorted[index])
        }
        var assignment = [Int](repeating: 0, count: sample.count)
        for _ in 0..<10 {
            for (i, c) in sample.enumerated() {
                var best = 0
                var bestD = Float.greatestFiniteMagnitude
                for (j, center) in centers.enumerated() {
                    let dist = distanceSquared(c, center)
                    if dist < bestD { bestD = dist; best = j }
                }
                assignment[i] = best
            }
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            var counts = [Int](repeating: 0, count: k)
            for (i, c) in sample.enumerated() { sums[assignment[i]] += c; counts[assignment[i]] += 1 }
            for j in 0..<k where counts[j] > 0 { centers[j] = sums[j] / Float(counts[j]) }
        }
        var close = 0
        for c in sample {
            var nearest: Float = 1
            for center in centers { nearest = Swift.min(nearest, distanceSquared(c, center)) }
            if nearest < 0.01 { close += 1 }
        }
        return (centers.sorted { luma($0) < luma($1) }, Float(close) / Float(sample.count))
    }
}
