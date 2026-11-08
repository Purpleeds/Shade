import Foundation

/// Looks that ship with the app. Two of them use custom Metal code to show what Claude-written passes look like.
public enum Presets {
    // Fixed ids so the "current recipe" survives relaunches.
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    public static let original = ShaderRecipe(id: id(1), name: "Original", description: "No effect.", author: "Shade", passes: [])

    public static let neonEdgesCode = """
    float4 shade(float2 uv, float2 res, float time, texture2d<float> tex, texture2d<float> orig, sampler smp, constant ShadeParams& P) {
        float e = sobel(tex, smp, uv, float2(P.width) / res);
        float hue = fract(uv.y * 0.5 + uv.x * 0.3 + time * P.speed);
        float3 neon = hsv2rgb(float3(hue, 0.85, 1.0));
        float3 base = SRC(uv).rgb * P.darkness;
        float glow = smoothstep(0.1, 0.6, e) * P.glow;
        return float4(base + neon * glow, 1.0);
    }
    """

    public static let underwaterCode = """
    float4 shade(float2 uv, float2 res, float time, texture2d<float> tex, texture2d<float> orig, sampler smp, constant ShadeParams& P) {
        float2 w = float2(sin(uv.y * 18.0 + time * 1.7), cos(uv.x * 14.0 + time * 1.3)) * 0.004 * P.wobble;
        float3 c = SRC(uv + w).rgb;
        float2 q = uv * float2(res.x / res.y, 1.0) * 6.0;
        float n = fbm(q + float2(time * 0.3, time * 0.2));
        float caust = pow(1.0 - abs(n * 2.0 - 1.0), 6.0) * P.caustics;
        c = c * float3(P.water) + caust * float3(0.6, 0.9, 1.0) * (1.0 - uv.y * 0.6);
        return float4(c, 1.0);
    }
    """

    public static func find(_ id: UUID) -> ShaderRecipe? { all.first { $0.id == id } }

    public static let all: [ShaderRecipe] = [
        original,
        ShaderRecipe(id: id(2), name: "Comic Book", description: "Flat colors, ink outlines and print dots.", author: "Shade", passes: [
            .builtIn("colorGrade", ["saturation": [1.4], "contrast": [1.15]]),
            .builtIn("posterize", ["levels": [5]]),
            .builtIn("halftone", ["dotSize": [7]], mix: 0.35),
            .builtIn("edges", ["threshold": [0.3], "thickness": [1.5]])
        ]),
        ShaderRecipe(id: id(3), name: "Neon Edges", description: "Glowing rainbow outlines on a dark world.", author: "Shade", passes: [
            ShaderPass(name: "Neon edges", code: neonEdgesCode, params: [
                .float("width", 1.5, 0.5, 4),
                .float("speed", 0.1, 0, 1),
                .float("darkness", 0.15, 0, 1),
                .float("glow", 1.6, 0, 4)
            ]),
            .builtIn("bloom", ["threshold": [0.4], "intensity": [1.0]])
        ]),
        ShaderRecipe(id: id(4), name: "Retro CRT", description: "Chunky pixels on an old TV.", author: "Shade", passes: [
            .builtIn("pixelate", ["size": [6]]),
            .builtIn("chromaticAberration", ["amount": [0.015]]),
            .builtIn("scanlines"),
            .builtIn("vignette", ["strength": [0.8]])
        ]),
        ShaderRecipe(id: id(5), name: "Film Noir", description: "High-contrast black and white with grain.", author: "Shade", passes: [
            .builtIn("colorGrade", ["saturation": [0], "contrast": [1.45], "exposure": [-0.1]]),
            .builtIn("grain", ["amount": [0.12]]),
            .builtIn("vignette", ["strength": [0.85], "radius": [1.0]])
        ]),
        ShaderRecipe(id: id(6), name: "Pocket Console", description: "Four shades of green, dithered.", author: "Shade", passes: [
            .builtIn("pixelate", ["size": [5]]),
            .builtIn("dither", ["levels": [4], "scale": [5]]),
            .builtIn("paletteMap", [
                "c0": [0.06, 0.22, 0.06], "c1": [0.19, 0.38, 0.19], "c2": [0.43, 0.58, 0.18],
                "c3": [0.55, 0.67, 0.06], "c4": [0.61, 0.74, 0.06]
            ])
        ]),
        ShaderRecipe(id: id(7), name: "Dreamy", description: "Warm, soft and glowing.", author: "Shade", passes: [
            .builtIn("colorGrade", ["temperature": [0.35], "contrast": [0.9], "exposure": [0.15]]),
            .builtIn("bloom", ["threshold": [0.5], "intensity": [1.5], "radius": [60]]),
            .builtIn("vignette", ["strength": [0.4], "color": [0.35, 0.15, 0.3]])
        ]),
        ShaderRecipe(id: id(8), name: "Oil Painting", description: "Painterly brush strokes.", author: "Shade", passes: [
            .builtIn("kuwahara", ["radius": [5], "spacing": [1.8]]),
            .builtIn("colorGrade", ["saturation": [1.25], "contrast": [1.1]]),
            .builtIn("sharpen", ["amount": [0.4]])
        ]),
        ShaderRecipe(id: id(9), name: "Pencil Sketch", description: "Graphite on paper.", author: "Shade", passes: [
            .builtIn("sketch"),
            .builtIn("grain", ["amount": [0.05], "size": [1]])
        ]),
        ShaderRecipe(id: id(10), name: "Thermal", description: "Predator-vision heat map.", author: "Shade", passes: [
            .builtIn("blur", ["radius": [6]]),
            .builtIn("thermal"),
            .builtIn("scanlines", ["strength": [0.15], "rgbMask": [0]])
        ]),
        ShaderRecipe(id: id(11), name: "Vaporwave", description: "Pink and cyan duotone with VHS artifacts.", author: "Shade", passes: [
            .builtIn("duotone", ["shadows": [0.15, 0.05, 0.4], "highlights": [0.3, 0.95, 0.95]]),
            .builtIn("chromaticAberration", ["amount": [0.03]]),
            .builtIn("glitch", ["amount": [0.25]]),
            .builtIn("scanlines", ["count": [300], "strength": [0.25]])
        ]),
        ShaderRecipe(id: id(12), name: "Underwater", description: "Wobbling water with caustic light.", author: "Shade", passes: [
            ShaderPass(name: "Caustics", code: underwaterCode, params: [
                .float("wobble", 1, 0, 3),
                .float("caustics", 0.5, 0, 1.5),
                .color("water", 0.55, 0.85, 1.0)
            ]),
            .builtIn("vignette", ["strength": [0.6], "color": [0.0, 0.08, 0.2]])
        ]),
        ShaderRecipe(id: id(13), name: "Night Vision", description: "Green phosphor goggles.", author: "Shade", passes: [
            .builtIn("colorGrade", ["saturation": [0], "exposure": [0.6], "contrast": [1.3], "tint": [0.35, 1.0, 0.4]]),
            .builtIn("grain", ["amount": [0.2], "size": [1.2]]),
            .builtIn("scanlines", ["count": [700], "strength": [0.2], "rgbMask": [0]]),
            .builtIn("vignette", ["strength": [1.0], "radius": [0.9], "softness": [0.4]])
        ])
    ]
}
