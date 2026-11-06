import UIKit

/// Offline "style match": measures a reference image (palette, tone, saturation, grain, edges, vignetting)
/// and builds a recipe from built-in effects. No network or API key needed; less clever than Claude, but instant.
enum StyleAnalyzer {
    struct Analysis {
        var palette: [SIMD3<Float>]      // sorted dark -> light
        var paletteCoverage: Float       // share of pixels close to a palette color (flat-color art scores high)
        var meanLuma: Float
        var lumaStd: Float
        var meanSaturation: Float
        var warmth: Float                // red-vs-blue balance, -1...1
        var meanColor: SIMD3<Float>
        var grain: Float                 // high-frequency noise level
        var edgeDensity: Float           // share of pixels on strong edges
        var vignette: Float              // how much darker the corners are than the center
    }

    static func analyze(_ image: UIImage) -> Analysis? {
        let size = 160
        guard let cg = ImageUtils.normalizedCGImage(image, maxDimension: 1024) else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let raw = ctx.data else { return nil }
        let pixels = UnsafeBufferPointer(start: raw.bindMemory(to: UInt8.self, capacity: size * size * 4), count: size * size * 4)

        var colors = [SIMD3<Float>](repeating: .zero, count: size * size)
        var lumas = [Float](repeating: 0, count: size * size)
        for i in 0..<(size * size) {
            let c = SIMD3<Float>(Float(pixels[i * 4]), Float(pixels[i * 4 + 1]), Float(pixels[i * 4 + 2])) / 255
            colors[i] = c
            lumas[i] = luma(c)
        }
        let n = Float(colors.count)

        let meanLuma = lumas.reduce(0, +) / n
        let lumaStd = sqrt(lumas.reduce(0) { $0 + ($1 - meanLuma) * ($1 - meanLuma) } / n)
        let meanColor = colors.reduce(SIMD3<Float>.zero, +) / n
        let meanSaturation = colors.reduce(Float(0)) { acc, c in
            let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
            return acc + (mx > 0.001 ? (mx - mn) / mx : 0)
        } / n
        let warmth = max(-1, min(1, (meanColor.x - meanColor.z) * 2.5))

        // Grain and edges from the luminance image.
        var residual: Float = 0
        var strongEdges = 0
        for y in 1..<(size - 1) {
            for x in 1..<(size - 1) {
                let i = y * size + x
                let blur = (lumas[i - 1] + lumas[i + 1] + lumas[i - size] + lumas[i + size]) / 4
                residual += abs(lumas[i] - blur)
                let gx = lumas[i + 1] - lumas[i - 1]
                let gy = lumas[i + size] - lumas[i - size]
                if sqrt(gx * gx + gy * gy) > 0.25 { strongEdges += 1 }
            }
        }
        let inner = Float((size - 2) * (size - 2))
        let grain = residual / inner
        let edgeDensity = Float(strongEdges) / inner

        // Vignette: corners vs center brightness.
        func regionLuma(_ x0: Int, _ y0: Int, _ w: Int) -> Float {
            var s: Float = 0
            for y in y0..<(y0 + w) { for x in x0..<(x0 + w) { s += lumas[y * size + x] } }
            return s / Float(w * w)
        }
        let w = size / 8
        let corners = (regionLuma(0, 0, w) + regionLuma(size - w, 0, w) + regionLuma(0, size - w, w) + regionLuma(size - w, size - w, w)) / 4
        let center = regionLuma(size / 2 - w, size / 2 - w, w * 2)
        let vignette = max(0, center - corners)

        let (palette, coverage) = kMeans(colors, k: 5)
        return Analysis(palette: palette, paletteCoverage: coverage, meanLuma: meanLuma, lumaStd: lumaStd,
                        meanSaturation: meanSaturation, warmth: warmth, meanColor: meanColor, grain: grain,
                        edgeDensity: edgeDensity, vignette: vignette)
    }

    static func recipe(from image: UIImage, name: String = "Style Match") -> ShaderRecipe? {
        guard let a = analyze(image) else { return nil }
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

    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

    private static func lerp3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: SIMD3<Float>) -> SIMD3<Float> { a + (b - a) * t }

    /// Small k-means in RGB. Returns centers sorted by brightness and the share of pixels within 0.1 of a center.
    private static func kMeans(_ colors: [SIMD3<Float>], k: Int) -> ([SIMD3<Float>], Float) {
        let sample = stride(from: 0, to: colors.count, by: 3).map { colors[$0] }
        guard !sample.isEmpty else { return ([], 0) }
        // Seed with luminance quantiles for stable, well-spread starting points.
        let sorted = sample.sorted { luma($0) < luma($1) }
        var centers = (0..<k).map { sorted[min(sorted.count - 1, ($0 * 2 + 1) * sorted.count / (2 * k))] }
        var assignment = [Int](repeating: 0, count: sample.count)
        for _ in 0..<10 {
            for (i, c) in sample.enumerated() {
                var best = 0
                var bestD = Float.greatestFiniteMagnitude
                for (j, center) in centers.enumerated() {
                    let d = c - center
                    let dist = (d * d).sum()
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
            let nearest = centers.map { ($0 - c) * ($0 - c) }.map { $0.sum() }.min() ?? 1
            if nearest < 0.01 { close += 1 }
        }
        return (centers.sorted { luma($0) < luma($1) }, Float(close) / Float(sample.count))
    }
}
