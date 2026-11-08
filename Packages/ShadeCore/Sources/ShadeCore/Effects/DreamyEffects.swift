import Foundation

// Soft, glowing, light-filled looks.
// swiftlint:disable line_length
extension BuiltInEffects {
    static let dreamy: [BuiltInEffect] = [
        BuiltInEffect(
            id: "orton", displayName: "Orton Glow", category: .dreamy,
            summary: "The classic dreamy photo trick: a bright, blurred copy screened over the sharp image.",
            params: [
                .float("glow", 0.6, 0, 1),
                .float("radius", 20, 2, 60),
                .float("brightness", 0.4, 0, 1)
            ],
            code: """
            \(sig) {
                float3 base = SRC(uv).rgb;
                float3 acc = float3(0.0);
                for (int i = 0; i < 24; i++) {
                    float fi = float(i);
                    float rr = sqrt((fi + 0.5) / 24.0) * P.radius;
                    float a = fi * 2.39996;
                    acc += SRC(uv + float2(cos(a), sin(a)) * rr / res).rgb;
                }
                float3 blurred = saturate(acc / 24.0 * (1.0 + P.brightness));
                float3 screened = 1.0 - (1.0 - base) * (1.0 - blurred);
                float3 c = mix(base, screened, P.glow);
                c = mix(float3(luma(c)), c, 1.0 + P.glow * 0.15);
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "pastel", displayName: "Pastel", category: .dreamy,
            summary: "Soft, airy pastel colors: lifted tones, gentle saturation and a candy tint.",
            params: [
                .float("softness", 0.5, 0, 1),
                .float("saturation", 0.7, 0, 1.5),
                .float("hueShift", 0, -0.2, 0.2, label: "Hue shift"),
                .color("tint", 1.0, 0.86, 0.95)
            ],
            code: """
            \(sig) {
                float3 hsv = rgb2hsv(saturate(SRC(uv).rgb));
                hsv.x = fract(hsv.x + P.hueShift);
                hsv.y *= P.saturation;
                hsv.z = mix(hsv.z, 0.55 + hsv.z * 0.45, P.softness);
                float3 c = hsv2rgb(hsv);
                c = c * mix(float3(1.0), float3(P.tint), 0.7) + float3(P.tint) * 0.06 * P.softness;
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "haze", displayName: "Dreamy Haze", category: .dreamy,
            summary: "Slowly drifting colored mist, thicker toward the top of the frame.",
            params: [
                .float("amount", 0.4, 0, 1),
                .float("height", 0.5, 0, 1, label: "Top-heavy"),
                .float("drift", 0.3, 0, 1),
                .color("color", 0.95, 0.88, 0.95)
            ],
            code: """
            \(sig) {
                float3 c = SRC(uv).rgb;
                float aspect = res.x / res.y;
                float t = time * P.drift;
                float n = fbm(float2(uv.x * aspect, uv.y) * 3.0 + float2(t * 0.1, t * 0.03));
                float grad = mix(1.0, 1.0 - smoothstep(0.0, 1.0, uv.y), P.height);
                float h = saturate(P.amount * grad * (0.6 + 0.6 * n));
                c = mix(c, float3(P.color), h);
                c = mix(float3(0.5), c, 1.0 - h * 0.2);
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "sparkles", displayName: "Sparkles", category: .dreamy,
            summary: "Twinkling star glints on the brightest spots.",
            params: [
                .float("threshold", 0.75, 0, 1, label: "Brightness needed"),
                .float("density", 0.5, 0, 1),
                .float("size", 8, 1, 20),
                .float("twinkle", 1.5, 0, 5),
                .color("color", 1.0, 0.97, 0.9)
            ],
            code: """
            \(sig) {
                float2 fc = uv * res;
                float cell = 28.0;
                float2 id0 = floor(fc / cell);
                float3 c = SRC(uv).rgb;
                float3 add = float3(0.0);
                for (int j = -1; j <= 1; j++) {
                    for (int i = -1; i <= 1; i++) {
                        float2 id = id0 + float2(float(i), float(j));
                        float2 h = hash22(id);
                        if (h.x > P.density) { continue; }
                        float2 pos = (id + 0.2 + 0.6 * hash22(id + 4.7)) * cell;
                        float b = luma(SRC(pos / res).rgb);
                        float k = saturate((b - P.threshold) / 0.15);
                        if (k <= 0.0) { continue; }
                        float tw = 0.5 + 0.5 * sin(time * P.twinkle * (1.0 + h.y) + h.y * 40.0);
                        float2 d = fc - pos;
                        float s = max(P.size * k * (0.4 + 0.6 * tw), 0.5);
                        float rays = exp(-abs(d.y) * 1.2) * exp(-abs(d.x) / s) + exp(-abs(d.x) * 1.2) * exp(-abs(d.y) / s);
                        float core = exp(-dot(d, d) / max(s * 0.3, 0.3));
                        add += float3(P.color) * (rays * 0.6 + core) * k * (0.3 + 0.7 * tw);
                    }
                }
                return float4(c + add, 1.0);
            }
            """),

        BuiltInEffect(
            id: "prism", displayName: "Prism Rainbow", category: .dreamy,
            summary: "Splits light into rainbow fringes toward the edges, with an iridescent sheen on highlights.",
            params: [
                .float("amount", 0.015, 0, 0.06, label: "Dispersion"),
                .float("sheen", 0.3, 0, 1),
                .float("speed", 0.05, 0, 1)
            ],
            code: """
            \(sig) {
                float2 dir = uv - 0.5;
                float3 acc = float3(0.0);
                float3 wsum = float3(0.0);
                for (int i = 0; i < 7; i++) {
                    float t = float(i) / 6.0;
                    float3 w = hsv2rgb(float3(t * 0.8, 1.0, 1.0));
                    acc += SRC(uv + dir * P.amount * (t - 0.5) * 2.0).rgb * w;
                    wsum += w;
                }
                float3 c = acc / max(wsum, float3(0.001));
                float3 sheen = hsv2rgb(float3(fract(uv.x * 0.6 + uv.y * 0.3 + time * P.speed), 0.5, 1.0));
                c += sheen * smoothstep(0.7, 1.0, luma(c)) * P.sheen;
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "tiltShift", displayName: "Tilt-Shift", category: .dreamy,
            summary: "Miniature-world look: one sharp horizontal band, everything else melts into blur. Tap the screen to move the band.",
            params: [
                .float("centerY", 0.55, 0, 1, label: "Focus position"),
                .float("band", 0.12, 0, 0.5, label: "Sharp band"),
                .float("blur", 12, 0, 30),
                .float("saturation", 1.3, 0, 2)
            ],
            code: """
            \(sig) {
                float amt = smoothstep(P.band, P.band + 0.25, abs(uv.y - P.centerY));
                float r = amt * P.blur;
                float3 acc = float3(0.0);
                for (int i = 0; i < 24; i++) {
                    float fi = float(i);
                    float rr = sqrt((fi + 0.5) / 24.0) * r;
                    float a = fi * 2.39996;
                    acc += SRC(uv + float2(cos(a), sin(a)) * rr / res).rgb;
                }
                float3 c = acc / 24.0;
                return float4(mix(float3(luma(c)), c, P.saturation), 1.0);
            }
            """),

        BuiltInEffect(
            id: "zoomBlur", displayName: "Zoom Blur", category: .dreamy,
            summary: "Radial rush of motion out of a clear center. Tap the screen to move the center.",
            params: [
                .float("strength", 0.08, 0, 0.3),
                .float("focus", 0.1, 0, 0.5, label: "Clear radius"),
                .float("centerX", 0.5, 0, 1, label: "Center X"),
                .float("centerY", 0.5, 0, 1, label: "Center Y")
            ],
            code: """
            \(sig) {
                float2 ctr = float2(P.centerX, P.centerY);
                float2 d = uv - ctr;
                float fade = smoothstep(P.focus, P.focus + 0.3, length(d * float2(res.x / res.y, 1.0)));
                float3 acc = float3(0.0);
                for (int i = 0; i < 16; i++) {
                    float t = float(i) / 15.0;
                    acc += SRC(ctr + d * (1.0 - P.strength * fade * t)).rgb;
                }
                return float4(acc / 16.0, 1.0);
            }
            """),

        BuiltInEffect(
            id: "trails", displayName: "Dream Trails", category: .dreamy,
            summary: "Moving things leave glowing, fading trails (uses the previous frame). Drift slowly zooms the trails outward.",
            params: [
                .float("persistence", 0.85, 0, 0.97, label: "Trail length"),
                .float("lighten", 0.6, 0, 1, label: "Glowing trails"),
                .float("drift", 0.004, -0.02, 0.02),
                .float("hueDrift", 0, 0, 0.05, label: "Rainbow drift")
            ],
            usesHistory: true,
            code: """
            \(sig) {
                float2 pp = 0.5 + (uv - 0.5) * (1.0 - P.drift);
                float3 prev = ORIG(pp).rgb;
                if (P.hueDrift > 0.0) {
                    float3 hsv = rgb2hsv(saturate(prev));
                    hsv.x = fract(hsv.x + P.hueDrift);
                    prev = hsv2rgb(hsv);
                }
                float3 cur = SRC(uv).rgb;
                float3 blended = mix(cur, prev, P.persistence);
                float3 lit = max(cur, prev * P.persistence);
                return float4(mix(blended, lit, P.lighten), 1.0);
            }
            """)
    ]
}
// swiftlint:enable line_length
