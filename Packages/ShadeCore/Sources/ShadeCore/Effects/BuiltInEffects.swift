import Foundation

public struct BuiltInEffect: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let params: [ShaderParam]
    /// MSL defining `float4 shade(...)` with the standard signature.
    public let code: String
}

// swiftlint:disable line_length
public enum BuiltInEffects {
    public static func find(_ name: String) -> BuiltInEffect? {
        let key = normalizedKey(name)
        return all.first { normalizedKey($0.id) == key } ?? aliases[key].flatMap { alias in all.first { $0.id == alias } }
    }

    public static func normalizedKey(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static let aliases: [String: String] = [
        "chromatic": "chromaticAberration",
        "rgbsplit": "chromaticAberration",
        "outline": "edges",
        "inkoutline": "edges",
        "sobel": "edges",
        "filmgrain": "grain",
        "noise": "grain",
        "gradientmap": "paletteMap",
        "palette": "paletteMap",
        "crt": "scanlines",
        "glow": "bloom",
        "painterly": "kuwahara",
        "oilpaint": "kuwahara",
        "heatmap": "thermal",
        "bayer": "dither",
        "ripple": "wave",
        "hue": "hueShift",
        "pencil": "sketch",
        "grade": "colorGrade",
        "colorgrading": "colorGrade",
        "pixel": "pixelate",
        "mosaic": "pixelate"
    ]

    static let sig = ShaderSource.signature

    public static let all: [BuiltInEffect] = [
        BuiltInEffect(
            id: "colorGrade", displayName: "Color Grade",
            summary: "Exposure, contrast, saturation, temperature, gamma and a multiply tint.",
            params: [
                .float("exposure", 0, -2, 2),
                .float("contrast", 1, 0, 2),
                .float("saturation", 1, 0, 2),
                .float("temperature", 0, -1, 1),
                .float("gamma", 1, 0.3, 3),
                .color("tint", 1, 1, 1)
            ],
            code: """
            \(sig) {
                float3 c = SRC(uv).rgb;
                c *= exp2(P.exposure);
                c = (c - 0.5) * P.contrast + 0.5;
                c = mix(float3(luma(c)), c, P.saturation);
                c += float3(P.temperature * 0.12, P.temperature * 0.02, -P.temperature * 0.12);
                c = max(c, float3(0.0));
                c = pow(c, float3(1.0 / max(P.gamma, 0.01)));
                c *= float3(P.tint);
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "posterize", displayName: "Posterize",
            summary: "Reduces each color channel to a few flat levels (cel / poster look).",
            params: [.float("levels", 5, 2, 16)],
            code: """
            \(sig) {
                float3 c = SRC(uv).rgb;
                float l = max(floor(P.levels), 2.0) - 1.0;
                c = floor(c * l + 0.5) / l;
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "edges", displayName: "Ink Outlines",
            summary: "Draws outlines where the image has strong edges (Sobel).",
            params: [
                .float("threshold", 0.25, 0, 1),
                .float("thickness", 1.2, 0.5, 5),
                .color("color", 0, 0, 0)
            ],
            code: """
            \(sig) {
                float e = sobel(tex, smp, uv, float2(P.thickness) / res);
                float k = smoothstep(P.threshold, P.threshold + 0.15, e);
                float3 c = SRC(uv).rgb;
                return float4(mix(c, float3(P.color), k), 1.0);
            }
            """),

        BuiltInEffect(
            id: "pixelate", displayName: "Pixelate",
            summary: "Big square pixels. size is the pixel size in camera pixels.",
            params: [.float("size", 10, 2, 80)],
            code: """
            \(sig) {
                float2 cell = float2(max(P.size, 1.0)) / res;
                float2 p = (floor(uv / cell) + 0.5) * cell;
                return SRC(p);
            }
            """),

        BuiltInEffect(
            id: "chromaticAberration", displayName: "Chromatic Aberration",
            summary: "Splits red and blue outward from the center like a cheap lens.",
            params: [.float("amount", 0.02, 0, 0.1)],
            code: """
            \(sig) {
                float2 o = (uv - 0.5) * P.amount;
                float r = SRC(uv + o).r;
                float g = SRC(uv).g;
                float b = SRC(uv - o).b;
                return float4(r, g, b, 1.0);
            }
            """),

        BuiltInEffect(
            id: "vignette", displayName: "Vignette",
            summary: "Darkens (or tints) the corners.",
            params: [
                .float("strength", 0.7, 0, 1),
                .float("radius", 1.1, 0.2, 2),
                .float("softness", 0.6, 0.05, 1.5),
                .color("color", 0, 0, 0)
            ],
            code: """
            \(sig) {
                float2 d = (uv - 0.5) * float2(res.x / res.y, 1.0);
                float len = length(d) * 2.0;
                float v = smoothstep(P.radius - P.softness, P.radius, len) * P.strength;
                float3 c = SRC(uv).rgb;
                return float4(mix(c, float3(P.color), v), 1.0);
            }
            """),

        BuiltInEffect(
            id: "grain", displayName: "Film Grain",
            summary: "Animated film grain noise.",
            params: [
                .float("amount", 0.08, 0, 0.5),
                .float("size", 1.5, 0.5, 6)
            ],
            code: """
            \(sig) {
                float2 p = floor(uv * res / max(P.size, 0.5));
                float frame = floor(time * 24.0);
                float n = hash21(p + float2(frame * 17.0, frame * 31.0)) - 0.5;
                float3 c = SRC(uv).rgb;
                c += n * P.amount * (1.2 - luma(c) * 0.6);
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "scanlines", displayName: "CRT Scanlines",
            summary: "Rolling scanlines plus an RGB sub-pixel mask.",
            params: [
                .float("count", 500, 100, 1500),
                .float("strength", 0.35, 0, 1),
                .float("speed", 0.5, 0, 5),
                .float("rgbMask", 0.3, 0, 1)
            ],
            code: """
            \(sig) {
                float s = sin((uv.y + time * P.speed * 0.02) * P.count * PI);
                float3 c = SRC(uv).rgb * (1.0 - P.strength * (0.5 - 0.5 * s));
                float m = fmod(floor(uv.x * res.x), 3.0);
                float lo = 1.0 - P.rgbMask;
                float3 mask = float3(m < 0.5 ? 1.0 : lo, (m >= 0.5 && m < 1.5) ? 1.0 : lo, m >= 1.5 ? 1.0 : lo);
                c *= mix(float3(1.0), mask, 0.8);
                c *= 1.0 + P.rgbMask * 0.35;
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "halftone", displayName: "Halftone",
            summary: "Comic-print dots on paper. colorful=1 keeps the dot colors.",
            params: [
                .float("dotSize", 9, 3, 40),
                .float("angle", 0.785, 0, 1.571),
                .float("colorful", 1, 0, 1),
                .color("paper", 1, 0.98, 0.93)
            ],
            code: """
            \(sig) {
                float2 frag = uv * res;
                float s = sin(P.angle);
                float co = cos(P.angle);
                float2 r = float2(co * frag.x - s * frag.y, s * frag.x + co * frag.y);
                float size = max(P.dotSize, 2.0);
                float2 center = (floor(r / size) + 0.5) * size;
                float2 back = float2(co * center.x + s * center.y, -s * center.x + co * center.y);
                float3 col = SRC(back / res).rgb;
                float radius = sqrt(saturate(1.0 - luma(col))) * size * 0.72;
                float d = length(r - center);
                float ink = 1.0 - smoothstep(radius - 1.0, radius + 1.0, d);
                float3 inkColor = mix(float3(0.06), col * 0.85, P.colorful);
                return float4(mix(float3(P.paper), inkColor, ink), 1.0);
            }
            """),

        BuiltInEffect(
            id: "paletteMap", displayName: "Palette Map",
            summary: "Gradient-maps brightness onto 5 colors (c0 = shadows ... c4 = highlights).",
            params: [
                .color("c0", 0.08, 0.04, 0.16),
                .color("c1", 0.35, 0.10, 0.40),
                .color("c2", 0.85, 0.25, 0.35),
                .color("c3", 0.98, 0.60, 0.30),
                .color("c4", 1.00, 0.95, 0.75)
            ],
            code: """
            \(sig) {
                float l = luma(SRC(uv).rgb);
                return float4(gradient5(l, float3(P.c0), float3(P.c1), float3(P.c2), float3(P.c3), float3(P.c4)), 1.0);
            }
            """),

        BuiltInEffect(
            id: "duotone", displayName: "Duotone",
            summary: "Two-color print: shadows -> one color, highlights -> another.",
            params: [
                .color("shadows", 0.10, 0.05, 0.35),
                .color("highlights", 1.0, 0.55, 0.65),
                .float("contrast", 1.1, 0.3, 3)
            ],
            code: """
            \(sig) {
                float l = saturate((luma(SRC(uv).rgb) - 0.5) * P.contrast + 0.5);
                return float4(mix(float3(P.shadows), float3(P.highlights), l), 1.0);
            }
            """),

        BuiltInEffect(
            id: "bloom", displayName: "Bloom",
            summary: "Soft glow around bright areas.",
            params: [
                .float("threshold", 0.65, 0, 1),
                .float("intensity", 1.2, 0, 4),
                .float("radius", 30, 2, 120),
                .color("tint", 1, 1, 1)
            ],
            code: """
            \(sig) {
                float3 base = SRC(uv).rgb;
                float3 acc = float3(0.0);
                for (int i = 0; i < 32; i++) {
                    float fi = float(i);
                    float rr = sqrt((fi + 0.5) / 32.0) * P.radius;
                    float a = fi * 2.39996;
                    float2 o = float2(cos(a), sin(a)) * rr / res;
                    float3 s = SRC(uv + o).rgb;
                    acc += max(s - float3(P.threshold), float3(0.0));
                }
                acc /= 32.0;
                return float4(base + acc * P.intensity * 2.0 * float3(P.tint), 1.0);
            }
            """),

        BuiltInEffect(
            id: "blur", displayName: "Blur",
            summary: "Soft lens blur (radius in camera pixels).",
            params: [.float("radius", 12, 0, 80)],
            code: """
            \(sig) {
                float3 acc = float3(0.0);
                for (int i = 0; i < 32; i++) {
                    float fi = float(i);
                    float rr = sqrt((fi + 0.5) / 32.0) * P.radius;
                    float a = fi * 2.39996;
                    acc += SRC(uv + float2(cos(a), sin(a)) * rr / res).rgb;
                }
                return float4(acc / 32.0, 1.0);
            }
            """),

        BuiltInEffect(
            id: "sharpen", displayName: "Sharpen",
            summary: "Unsharp-mask style detail boost.",
            params: [.float("amount", 0.8, 0, 3)],
            code: """
            \(sig) {
                float2 px = 1.0 / res;
                float3 c = SRC(uv).rgb;
                float3 n = SRC(uv + float2(px.x, 0.0)).rgb + SRC(uv - float2(px.x, 0.0)).rgb
                         + SRC(uv + float2(0.0, px.y)).rgb + SRC(uv - float2(0.0, px.y)).rgb;
                return float4(c + (c * 4.0 - n) * P.amount, 1.0);
            }
            """),

        BuiltInEffect(
            id: "kuwahara", displayName: "Oil Paint",
            summary: "Kuwahara filter: flattens detail into painterly brush strokes.",
            params: [
                .float("radius", 4, 1, 6),
                .float("spacing", 1.5, 1, 4)
            ],
            code: """
            \(sig) {
                int r = int(clamp(P.radius, 1.0, 6.0));
                float2 px = float2(P.spacing) / res;
                float3 m0 = float3(0.0), m1 = float3(0.0), m2 = float3(0.0), m3 = float3(0.0);
                float3 s0 = float3(0.0), s1 = float3(0.0), s2 = float3(0.0), s3 = float3(0.0);
                for (int j = -r; j <= r; j++) {
                    for (int i = -r; i <= r; i++) {
                        float3 c = SRC(uv + float2(float(i), float(j)) * px).rgb;
                        float3 c2 = c * c;
                        if (i <= 0 && j <= 0) { m0 += c; s0 += c2; }
                        if (i >= 0 && j <= 0) { m1 += c; s1 += c2; }
                        if (i <= 0 && j >= 0) { m2 += c; s2 += c2; }
                        if (i >= 0 && j >= 0) { m3 += c; s3 += c2; }
                    }
                }
                float n = float((r + 1) * (r + 1));
                m0 /= n; m1 /= n; m2 /= n; m3 /= n;
                float3 v0 = abs(s0 / n - m0 * m0);
                float3 v1 = abs(s1 / n - m1 * m1);
                float3 v2 = abs(s2 / n - m2 * m2);
                float3 v3 = abs(s3 / n - m3 * m3);
                float best = v0.r + v0.g + v0.b;
                float3 outc = m0;
                float t = v1.r + v1.g + v1.b;
                if (t < best) { best = t; outc = m1; }
                t = v2.r + v2.g + v2.b;
                if (t < best) { best = t; outc = m2; }
                t = v3.r + v3.g + v3.b;
                if (t < best) { best = t; outc = m3; }
                return float4(outc, 1.0);
            }
            """),

        BuiltInEffect(
            id: "thermal", displayName: "Thermal",
            summary: "False-color heat camera look.",
            params: [
                .float("contrast", 1.3, 0.5, 3),
                .float("offset", 0, -0.5, 0.5)
            ],
            code: """
            \(sig) {
                float l = saturate((luma(SRC(uv).rgb) - 0.5) * P.contrast + 0.5 + P.offset);
                float3 c = gradient5(l, float3(0.0, 0.0, 0.1), float3(0.25, 0.0, 0.6), float3(0.9, 0.05, 0.3),
                                     float3(1.0, 0.65, 0.0), float3(1.0, 1.0, 0.85));
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "dither", displayName: "Dither",
            summary: "Ordered (Bayer) dithering into a few levels, retro 1-bit style. Pair with paletteMap for Game Boy looks.",
            params: [
                .float("levels", 2, 2, 8),
                .float("scale", 3, 1, 10),
                .float("colorful", 0, 0, 1)
            ],
            code: """
            \(sig) {
                float sc = max(P.scale, 1.0);
                float2 p = floor(uv * res / sc);
                int x = int(fmod(p.x, 4.0));
                int y = int(fmod(p.y, 4.0));
                float bayer[16] = { 0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0 };
                float th = (bayer[y * 4 + x] + 0.5) / 16.0 - 0.5;
                float3 c = SRC((p + 0.5) * sc / res).rgb;
                float l = max(floor(P.levels), 2.0) - 1.0;
                float3 q = floor(c * l + th + 0.5) / l;
                float3 mono = float3(floor(luma(c) * l + th + 0.5) / l);
                return float4(mix(mono, q, P.colorful), 1.0);
            }
            """),

        BuiltInEffect(
            id: "wave", displayName: "Wave Distortion",
            summary: "Animated wobbly / underwater distortion.",
            params: [
                .float("amplitude", 0.01, 0, 0.06),
                .float("frequency", 20, 1, 80),
                .float("speed", 2, 0, 10)
            ],
            code: """
            \(sig) {
                float2 o = float2(sin(uv.y * P.frequency + time * P.speed),
                                  cos(uv.x * P.frequency * 0.8 + time * P.speed * 1.3)) * P.amplitude;
                return SRC(uv + o);
            }
            """),

        BuiltInEffect(
            id: "kaleidoscope", displayName: "Kaleidoscope",
            summary: "Mirrors the image into rotating segments.",
            params: [
                .float("segments", 6, 2, 16),
                .float("speed", 0.2, 0, 2),
                .float("zoom", 1, 0.3, 3)
            ],
            code: """
            \(sig) {
                float aspect = res.x / res.y;
                float2 p = (uv - 0.5) * float2(aspect, 1.0);
                float r = length(p) / max(P.zoom, 0.05);
                float a = atan2(p.y, p.x) + time * P.speed;
                float seg = TAU / max(floor(P.segments), 1.0);
                a = a - seg * floor(a / seg);
                a = abs(a - seg * 0.5);
                float2 q = float2(cos(a), sin(a)) * r;
                q.x /= aspect;
                return SRC(q + 0.5);
            }
            """),

        BuiltInEffect(
            id: "glitch", displayName: "Glitch",
            summary: "Digital block tearing and RGB shifts.",
            params: [
                .float("amount", 0.5, 0, 1),
                .float("speed", 3, 0.1, 15),
                .float("blockSize", 40, 4, 200)
            ],
            code: """
            \(sig) {
                float t = floor(time * P.speed);
                float row = floor(uv.y * res.y / max(P.blockSize, 1.0));
                float h = hash21(float2(row, t));
                float shift = (h > 1.0 - P.amount * 0.5) ? (hash21(float2(t, row)) - 0.5) * 0.2 * P.amount : 0.0;
                float2 u = float2(fract(uv.x + shift), uv.y);
                float split = 0.012 * P.amount * hash21(float2(t, 3.0));
                float r = SRC(u + float2(split, 0.0)).r;
                float g = SRC(u).g;
                float b = SRC(u - float2(split, 0.0)).b;
                return float4(r, g, b, 1.0);
            }
            """),

        BuiltInEffect(
            id: "hueShift", displayName: "Hue Shift",
            summary: "Rotates hues; speed > 0 cycles them over time.",
            params: [
                .float("shift", 0, 0, 1),
                .float("speed", 0, 0, 1)
            ],
            code: """
            \(sig) {
                float3 hsv = rgb2hsv(SRC(uv).rgb);
                hsv.x = fract(hsv.x + P.shift + time * P.speed);
                return float4(hsv2rgb(hsv), 1.0);
            }
            """),

        BuiltInEffect(
            id: "sketch", displayName: "Pencil Sketch",
            summary: "Pencil lines and cross-hatching on paper.",
            params: [
                .float("intensity", 1.5, 0.3, 4),
                .float("hatching", 0.5, 0, 1),
                .color("paper", 0.96, 0.94, 0.88),
                .color("ink", 0.15, 0.15, 0.2)
            ],
            code: """
            \(sig) {
                float e = sobel(tex, smp, uv, float2(1.5) / res) * P.intensity;
                float dark = 1.0 - luma(SRC(uv).rgb);
                float2 fc = uv * res;
                float h1 = smoothstep(0.55, 1.0, sin((fc.x + fc.y) * 0.7) * 0.5 + 0.5) * step(0.45, dark);
                float h2 = smoothstep(0.55, 1.0, sin((fc.x - fc.y) * 0.7) * 0.5 + 0.5) * step(0.7, dark);
                float ink = saturate(e + (h1 + h2) * P.hatching * 0.6);
                return float4(mix(float3(P.paper), float3(P.ink), ink), 1.0);
            }
            """),

        BuiltInEffect(
            id: "sepia", displayName: "Sepia",
            summary: "Old-photo brown toning.",
            params: [],
            code: """
            \(sig) {
                float3 c = SRC(uv).rgb;
                float3 s = float3(dot(c, float3(0.393, 0.769, 0.189)),
                                  dot(c, float3(0.349, 0.686, 0.168)),
                                  dot(c, float3(0.272, 0.534, 0.131)));
                return float4(s, 1.0);
            }
            """),

        BuiltInEffect(
            id: "invert", displayName: "Invert",
            summary: "Negative image.",
            params: [],
            code: """
            \(sig) {
                return float4(1.0 - SRC(uv).rgb, 1.0);
            }
            """),

        BuiltInEffect(
            id: "mirror", displayName: "Mirror",
            summary: "Mirrors one half of the frame onto the other. vertical=1 mirrors top/bottom.",
            params: [.float("vertical", 0, 0, 1)],
            code: """
            \(sig) {
                float2 p = uv;
                if (P.vertical > 0.5) { p.y = p.y > 0.5 ? 1.0 - p.y : p.y; }
                else { p.x = p.x > 0.5 ? 1.0 - p.x : p.x; }
                return SRC(p);
            }
            """),

        BuiltInEffect(
            id: "blendOriginal", displayName: "Blend Original",
            summary: "Mixes the untouched camera image back in (screen/overlay style via mode: 0 normal, 1 screen, 2 multiply).",
            params: [
                .float("amount", 0.5, 0, 1),
                .float("mode", 0, 0, 2)
            ],
            code: """
            \(sig) {
                float3 a = SRC(uv).rgb;
                float3 b = ORIG(uv).rgb;
                float3 m = b;
                if (P.mode > 1.5) { m = a * b; }
                else if (P.mode > 0.5) { m = 1.0 - (1.0 - a) * (1.0 - b); }
                return float4(mix(a, m, P.amount), 1.0);
            }
            """)
    ]
}
// swiftlint:enable line_length
