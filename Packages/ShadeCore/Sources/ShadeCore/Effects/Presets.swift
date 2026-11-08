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

    public static func category(of id: UUID) -> PresetCategory? {
        sections.first { $0.recipes.contains { $0.id == id } }?.category
    }

    /// Every preset, in display order. Ids are fixed so a saved session can refer to them.
    public static let all: [ShaderRecipe] = sections.flatMap(\.recipes)

    public static let sections: [PresetSection] = [
        PresetSection(category: .basics, recipes: [original]),
        PresetSection(category: .nostalgic, recipes: [
            ShaderRecipe(id: id(14), name: "Super 8", description: "Warm, faded home-movie film with dust, flicker and light leaks.", author: "Shade", passes: [
                .builtIn("fade", ["fade": [0.14], "ceiling": [0.9], "saturation": [0.8], "tint": [1.0, 0.9, 0.8]]),
                .builtIn("colorGrade", ["temperature": [0.35], "contrast": [1.05]]),
                .builtIn("grain", ["amount": [0.14], "size": [2.2]]),
                .builtIn("dust", ["amount": [0.6], "scratches": [0.5]]),
                .builtIn("filmFlicker", ["flicker": [0.1], "weave": [0.004]]),
                .builtIn("lightLeak", ["intensity": [0.45]]),
                .builtIn("vignette", ["strength": [0.75], "radius": [1.0]])
            ]),
            ShaderRecipe(id: id(15), name: "Camcorder '98", description: "Family-video tape with a glowing date in the corner.", author: "Shade", passes: [
                .builtIn("colorGrade", ["saturation": [1.1], "temperature": [0.1]]),
                .builtIn("vhs"),
                .builtIn("scanlines", ["count": [480], "strength": [0.12], "rgbMask": [0], "speed": [0.2]]),
                .builtIn("dateStamp")
            ]),
            ShaderRecipe(id: id(16), name: "Faded Memory", description: "Soft matte blacks, teal shadows and warm highlights, like an old print in a shoebox.", author: "Shade", passes: [
                .builtIn("fade", ["fade": [0.18], "ceiling": [0.9], "saturation": [0.75], "tint": [0.95, 0.9, 1.0]]),
                .builtIn("splitTone", ["shadows": [0.15, 0.32, 0.4], "highlights": [1.0, 0.8, 0.55], "strength": [0.45]]),
                .builtIn("grain", ["amount": [0.07]]),
                .builtIn("vignette", ["strength": [0.5]])
            ]),
            ShaderRecipe(id: id(17), name: "Instant Summer", description: "Sun-bleached instant photo, framed and ready for the fridge door.", author: "Shade", passes: [
                .builtIn("crossProcess", ["strength": [0.45]]),
                .builtIn("fade", ["fade": [0.1], "ceiling": [0.95], "saturation": [1.0], "tint": [1.0, 0.95, 0.85]]),
                .builtIn("colorGrade", ["temperature": [0.25], "exposure": [0.1]]),
                .builtIn("vignette", ["strength": [0.35]]),
                .builtIn("instantFrame")
            ]),
            ShaderRecipe(id: id(18), name: "Silent Reel", description: "A 1920s projector: sepia, heavy grain, scratches and flicker.", author: "Shade", passes: [
                .builtIn("sepia"),
                .builtIn("colorGrade", ["contrast": [1.3]]),
                .builtIn("fade", ["fade": [0.06], "ceiling": [0.92], "saturation": [1.0], "tint": [1.0, 1.0, 1.0]]),
                .builtIn("grain", ["amount": [0.16], "size": [2]]),
                .builtIn("dust", ["amount": [0.8], "scratches": [0.7]]),
                .builtIn("filmFlicker", ["flicker": [0.2], "weave": [0.006], "speed": [16]]),
                .builtIn("vignette", ["strength": [0.9], "radius": [0.95]])
            ]),
            ShaderRecipe(id: id(19), name: "Lomo", description: "Toy-camera punch: cross-processed color, dark corners and lens fringing.", author: "Shade", passes: [
                .builtIn("crossProcess", ["strength": [0.8], "contrast": [1.3]]),
                .builtIn("colorGrade", ["saturation": [1.25]]),
                .builtIn("chromaticAberration", ["amount": [0.01]]),
                .builtIn("vignette", ["strength": [0.95], "radius": [0.85], "softness": [0.5]])
            ]),
            ShaderRecipe(id: id(5), name: "Film Noir", description: "High-contrast black and white with grain.", author: "Shade", passes: [
                .builtIn("colorGrade", ["saturation": [0], "contrast": [1.45], "exposure": [-0.1]]),
                .builtIn("grain", ["amount": [0.12]]),
                .builtIn("vignette", ["strength": [0.85], "radius": [1.0]])
            ])
        ]),
        PresetSection(category: .dreamy, recipes: [
            ShaderRecipe(id: id(20), name: "Golden Hour", description: "That last warm hour of sunlight, with a soft glow and drifting light.", author: "Shade", passes: [
                .builtIn("colorGrade", ["temperature": [0.5], "exposure": [0.1], "saturation": [1.1]]),
                .builtIn("splitTone", ["shadows": [0.35, 0.2, 0.3], "highlights": [1.0, 0.75, 0.4], "strength": [0.35]]),
                .builtIn("orton", ["glow": [0.35], "radius": [25]]),
                .builtIn("lightLeak", ["intensity": [0.35], "speed": [0.2]]),
                .builtIn("haze", ["amount": [0.2], "color": [1.0, 0.85, 0.6]])
            ]),
            ShaderRecipe(id: id(21), name: "Dreamscape", description: "Glowing, misty and pastel, with sparkles on the light.", author: "Shade", passes: [
                .builtIn("orton", ["glow": [0.7]]),
                .builtIn("pastel", ["softness": [0.45], "saturation": [0.85]]),
                .builtIn("haze", ["amount": [0.3]]),
                .builtIn("sparkles", ["threshold": [0.7]]),
                .builtIn("vignette", ["strength": [0.35], "color": [0.3, 0.2, 0.4]])
            ]),
            ShaderRecipe(id: id(22), name: "Cotton Candy", description: "Pink and baby-blue pastels with a soft bloom.", author: "Shade", passes: [
                .builtIn("pastel", ["softness": [0.6], "saturation": [0.9], "hueShift": [0.02], "tint": [1.0, 0.85, 0.95]]),
                .builtIn("splitTone", ["shadows": [0.55, 0.6, 0.95], "highlights": [1.0, 0.75, 0.9], "strength": [0.5]]),
                .builtIn("bloom", ["threshold": [0.55], "intensity": [0.9], "radius": [50]]),
                .builtIn("sparkles", ["density": [0.35]])
            ]),
            ShaderRecipe(id: id(23), name: "Ethereal Trails", description: "Movement leaves glowing ghost trails that drift outward.", author: "Shade", passes: [
                .builtIn("trails", ["persistence": [0.88], "lighten": [0.7], "drift": [0.006]]),
                .builtIn("orton", ["glow": [0.5]]),
                .builtIn("prism", ["amount": [0.012], "sheen": [0.2]])
            ]),
            ShaderRecipe(id: id(24), name: "Moonlight", description: "Cool blue night, silvery highlights and a faint starry shimmer.", author: "Shade", passes: [
                .builtIn("colorGrade", ["temperature": [-0.5], "exposure": [-0.2], "saturation": [0.6]]),
                .builtIn("splitTone", ["shadows": [0.1, 0.15, 0.35], "highlights": [0.8, 0.88, 1.0], "strength": [0.55]]),
                .builtIn("fade", ["fade": [0.08], "ceiling": [0.92], "saturation": [0.8], "tint": [0.8, 0.85, 1.0]]),
                .builtIn("sparkles", ["threshold": [0.65], "color": [0.85, 0.9, 1.0]]),
                .builtIn("haze", ["amount": [0.2], "color": [0.7, 0.75, 0.95]])
            ]),
            ShaderRecipe(id: id(25), name: "Prism Dream", description: "Light splits into slow-shifting rainbows.", author: "Shade", passes: [
                .builtIn("prism", ["amount": [0.025], "sheen": [0.5], "speed": [0.08]]),
                .builtIn("bloom", ["threshold": [0.5]]),
                .builtIn("hueShift", ["speed": [0.02]]),
                .builtIn("pastel", ["softness": [0.3], "saturation": [1.1]])
            ]),
            ShaderRecipe(id: id(26), name: "Daydream", description: "A soft rush toward the center through a white haze. Tap to move the center.", author: "Shade", passes: [
                .builtIn("zoomBlur", ["strength": [0.05], "focus": [0.2]]),
                .builtIn("orton", ["glow": [0.5]]),
                .builtIn("pastel", ["softness": [0.35]]),
                .builtIn("vignette", ["strength": [0.3], "color": [1.0, 0.95, 0.9]])
            ]),
            ShaderRecipe(id: id(27), name: "Miniature World", description: "Tilt-shift toy town. Tap to choose what stays sharp.", author: "Shade", passes: [
                .builtIn("tiltShift"),
                .builtIn("colorGrade", ["saturation": [1.3], "contrast": [1.1], "exposure": [0.1]])
            ]),
            ShaderRecipe(id: id(7), name: "Dreamy", description: "Warm, soft and glowing.", author: "Shade", passes: [
                .builtIn("colorGrade", ["temperature": [0.35], "contrast": [0.9], "exposure": [0.15]]),
                .builtIn("bloom", ["threshold": [0.5], "intensity": [1.5], "radius": [60]]),
                .builtIn("vignette", ["strength": [0.4], "color": [0.35, 0.15, 0.3]])
            ]),
            ShaderRecipe(id: id(12), name: "Underwater", description: "Wobbling water with caustic light.", author: "Shade", passes: [
                ShaderPass(name: "Caustics", code: underwaterCode, params: [
                    .float("wobble", 1, 0, 3),
                    .float("caustics", 0.5, 0, 1.5),
                    .color("water", 0.55, 0.85, 1.0)
                ]),
                .builtIn("vignette", ["strength": [0.6], "color": [0.0, 0.08, 0.2]])
            ])
        ]),
        PresetSection(category: .retro, recipes: [
            ShaderRecipe(id: id(4), name: "Retro CRT", description: "Chunky pixels on an old TV.", author: "Shade", passes: [
                .builtIn("pixelate", ["size": [6]]),
                .builtIn("chromaticAberration", ["amount": [0.015]]),
                .builtIn("scanlines"),
                .builtIn("vignette", ["strength": [0.8]])
            ]),
            ShaderRecipe(id: id(6), name: "Pocket Console", description: "Four shades of green, dithered.", author: "Shade", passes: [
                .builtIn("pixelate", ["size": [5]]),
                .builtIn("dither", ["levels": [4], "scale": [5]]),
                .builtIn("paletteMap", [
                    "c0": [0.06, 0.22, 0.06], "c1": [0.19, 0.38, 0.19], "c2": [0.43, 0.58, 0.18],
                    "c3": [0.55, 0.67, 0.06], "c4": [0.61, 0.74, 0.06]
                ])
            ]),
            ShaderRecipe(id: id(11), name: "Vaporwave", description: "Pink and cyan duotone with VHS artifacts.", author: "Shade", passes: [
                .builtIn("duotone", ["shadows": [0.15, 0.05, 0.4], "highlights": [0.3, 0.95, 0.95]]),
                .builtIn("chromaticAberration", ["amount": [0.03]]),
                .builtIn("glitch", ["amount": [0.25]]),
                .builtIn("scanlines", ["count": [300], "strength": [0.25]])
            ]),
            ShaderRecipe(id: id(28), name: "Haunted Tape", description: "A found-footage tape where moving things leave ghosts.", author: "Shade", passes: [
                .builtIn("trails", ["persistence": [0.7], "lighten": [0], "drift": [0]]),
                .builtIn("vhs", ["tracking": [0.7], "noise": [0.5]]),
                .builtIn("colorGrade", ["saturation": [0.3], "temperature": [-0.3]])
            ]),
            ShaderRecipe(id: id(29), name: "Hologram", description: "A flickering cyan projection with scan lines and glitches.", author: "Shade", passes: [
                .builtIn("duotone", ["shadows": [0.0, 0.05, 0.15], "highlights": [0.3, 1.0, 0.95]]),
                .builtIn("edges", ["threshold": [0.3], "color": [0.6, 1.0, 1.0]]),
                .builtIn("scanlines", ["count": [700], "strength": [0.35], "speed": [2], "rgbMask": [0]]),
                .builtIn("glitch", ["amount": [0.2]]),
                .builtIn("bloom", ["threshold": [0.5]])
            ])
        ]),
        PresetSection(category: .artistic, recipes: [
            ShaderRecipe(id: id(2), name: "Comic Book", description: "Flat colors, ink outlines and print dots.", author: "Shade", passes: [
                .builtIn("colorGrade", ["saturation": [1.4], "contrast": [1.15]]),
                .builtIn("posterize", ["levels": [5]]),
                .builtIn("halftone", ["dotSize": [7]], mix: 0.35),
                .builtIn("edges", ["threshold": [0.3], "thickness": [1.5]])
            ]),
            ShaderRecipe(id: id(30), name: "Pop Art", description: "Loud flat color, big print dots and bold outlines.", author: "Shade", passes: [
                .builtIn("colorGrade", ["saturation": [1.6], "contrast": [1.2]]),
                .builtIn("posterize", ["levels": [4]]),
                .builtIn("halftone", ["dotSize": [10], "colorful": [1]], mix: 0.6),
                .builtIn("edges", ["threshold": [0.25], "thickness": [2]])
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
            ShaderRecipe(id: id(3), name: "Neon Edges", description: "Glowing rainbow outlines on a dark world.", author: "Shade", passes: [
                ShaderPass(name: "Neon edges", code: neonEdgesCode, params: [
                    .float("width", 1.5, 0.5, 4),
                    .float("speed", 0.1, 0, 1),
                    .float("darkness", 0.15, 0, 1),
                    .float("glow", 1.6, 0, 4)
                ]),
                .builtIn("bloom", ["threshold": [0.4], "intensity": [1.0]])
            ])
        ]),
        PresetSection(category: .fun, recipes: [
            ShaderRecipe(id: id(10), name: "Thermal", description: "Predator-vision heat map.", author: "Shade", passes: [
                .builtIn("blur", ["radius": [6]]),
                .builtIn("thermal"),
                .builtIn("scanlines", ["strength": [0.15], "rgbMask": [0]])
            ]),
            ShaderRecipe(id: id(13), name: "Night Vision", description: "Green phosphor goggles.", author: "Shade", passes: [
                .builtIn("colorGrade", ["saturation": [0], "exposure": [0.6], "contrast": [1.3], "tint": [0.35, 1.0, 0.4]]),
                .builtIn("grain", ["amount": [0.2], "size": [1.2]]),
                .builtIn("scanlines", ["count": [700], "strength": [0.2], "rgbMask": [0]]),
                .builtIn("vignette", ["strength": [1.0], "radius": [0.9], "softness": [0.4]])
            ])
        ])
    ]
}

public enum PresetCategory: String, CaseIterable, Sendable {
    case basics, nostalgic, dreamy, retro, artistic, fun

    public var displayName: String {
        switch self {
        case .basics: return "Basics"
        case .nostalgic: return "Nostalgic"
        case .dreamy: return "Dreamy"
        case .retro: return "Retro Tech"
        case .artistic: return "Artistic"
        case .fun: return "Fun"
        }
    }
}

public struct PresetSection: Sendable {
    public let category: PresetCategory
    public let recipes: [ShaderRecipe]
}
