import Foundation

// Film, photo and home-video looks.
// swiftlint:disable line_length
extension BuiltInEffects {
    static let nostalgic: [BuiltInEffect] = [
        BuiltInEffect(
            id: "fade", displayName: "Faded Film", category: .film,
            summary: "Lifted, tinted blacks and softened whites: the matte look of old prints.",
            params: [
                .float("fade", 0.12, 0, 0.5, label: "Lift blacks"),
                .float("ceiling", 0.93, 0.5, 1, label: "Soften whites"),
                .float("saturation", 0.85, 0, 1.5),
                .color("tint", 1.0, 0.92, 0.85, label: "Shadow tint")
            ],
            code: """
            \(sig) {
                float3 c = SRC(uv).rgb;
                c = mix(float3(P.fade) * float3(P.tint), float3(P.ceiling), saturate(c));
                c = mix(float3(luma(c)), c, P.saturation);
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "splitTone", displayName: "Split Tone", category: .color,
            summary: "Tints shadows and highlights with two different colors (teal/orange, blue/gold...).",
            params: [
                .color("shadows", 0.10, 0.35, 0.45),
                .color("highlights", 1.0, 0.72, 0.42),
                .float("balance", 0, -1, 1),
                .float("strength", 0.5, 0, 1)
            ],
            code: """
            \(sig) {
                float3 c = SRC(uv).rgb;
                float l = luma(c);
                float w = smoothstep(0.0, 1.0, saturate(l + P.balance * 0.5));
                float3 tone = mix(float3(P.shadows), float3(P.highlights), w);
                float3 toned = tone * (l / max(luma(tone), 0.001));
                return float4(mix(c, toned, P.strength), 1.0);
            }
            """),

        BuiltInEffect(
            id: "lightLeak", displayName: "Light Leaks", category: .film,
            summary: "Warm, drifting glows bleeding in from the edges like light hitting old film.",
            params: [
                .float("intensity", 0.6, 0, 1.5),
                .float("speed", 0.3, 0, 2),
                .float("size", 0.7, 0.2, 1.5),
                .color("color", 1.0, 0.42, 0.18),
                .color("color2", 1.0, 0.82, 0.4, label: "Second color")
            ],
            code: """
            \(sig) {
                float aspect = res.x / res.y;
                float2 p = float2(uv.x * aspect, uv.y);
                float t = time * P.speed;
                float2 c1 = float2(-0.1 + 0.25 * sin(t * 0.7), 0.25 + 0.35 * sin(t * 0.43 + 1.0));
                float2 c2 = float2(aspect + 0.1 - 0.3 * sin(t * 0.5 + 2.0), 0.8 + 0.25 * cos(t * 0.37));
                float n = fbm(p * 2.0 + float2(t * 0.2, -t * 0.15));
                float s1 = max(P.size, 0.05);
                float s2 = max(P.size * 0.8, 0.05);
                float d1 = length(p - c1) / s1;
                float d2 = length(p - c2) / s2;
                float l1 = exp(-d1 * d1 * 2.0) * (0.6 + 0.8 * n);
                float l2 = exp(-d2 * d2 * 2.0) * (0.6 + 0.8 * (1.0 - n));
                float3 leak = saturate((float3(P.color) * l1 + float3(P.color2) * l2) * P.intensity);
                float3 base = SRC(uv).rgb;
                return float4(1.0 - (1.0 - base) * (1.0 - leak), 1.0);
            }
            """),

        BuiltInEffect(
            id: "dust", displayName: "Dust & Scratches", category: .film,
            summary: "Animated dust specks and vertical scratches of a worn film reel.",
            params: [
                .float("amount", 0.5, 0, 1, label: "Dust"),
                .float("scratches", 0.4, 0, 1)
            ],
            code: """
            \(sig) {
                float frame = floor(time * 18.0);
                float2 fc = uv * res;
                float3 c = SRC(uv).rgb;
                float cell = 40.0;
                float2 id = floor(fc / cell);
                float2 h = hash22(id + frame * 7.13);
                float present = step(1.0 - P.amount * 0.08, h.x);
                float2 speckPos = (id + hash22(id * 3.1 + frame)) * cell;
                float radius = mix(1.0, 3.5, h.y);
                float speck = present * (1.0 - smoothstep(radius * 0.5, radius, length(fc - speckPos)));
                float showScratch = step(1.0 - P.scratches * 0.6, hash21(float2(frame, 9.1)));
                float lineX = hash21(float2(frame, 1.7)) * res.x + sin(uv.y * 30.0 + frame) * 2.0;
                float scratch = showScratch * (1.0 - smoothstep(0.0, 1.5, abs(fc.x - lineX)))
                              * (0.5 + 0.5 * noise2(float2(fc.y * 0.05, frame)));
                c = mix(c, float3(0.08), speck * 0.85);
                c = mix(c, float3(0.95), scratch * 0.6);
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "filmFlicker", displayName: "Flicker & Gate Weave", category: .film,
            summary: "Projector brightness flicker and the slight frame wobble of old film.",
            params: [
                .float("flicker", 0.12, 0, 0.5),
                .float("weave", 0.003, 0, 0.012, label: "Frame weave"),
                .float("speed", 18, 1, 30, label: "Frames per second")
            ],
            code: """
            \(sig) {
                float frame = floor(time * P.speed);
                float2 jitter = (hash22(float2(frame, 3.3)) - 0.5) * P.weave * 2.0;
                float3 c = SRC(uv + jitter).rgb;
                float f = 1.0 + (hash21(float2(frame, 7.7)) - 0.5) * P.flicker * 2.0;
                return float4(c * f, 1.0);
            }
            """),

        BuiltInEffect(
            id: "crossProcess", displayName: "Cross Process", category: .film,
            summary: "Slide film developed in the wrong chemicals: punchy yellow-green highlights, cool lifted shadows (lomo look).",
            params: [
                .float("strength", 0.7, 0, 1),
                .float("contrast", 1.2, 0.5, 2)
            ],
            code: """
            \(sig) {
                float3 c = SRC(uv).rgb;
                float3 x = saturate(c);
                x.r = smoothstep(0.05, 0.95, x.r);
                x.g = smoothstep(-0.05, 1.0, x.g) * 1.04;
                x.b = x.b * 0.75 + 0.12;
                x = (x - 0.5) * P.contrast + 0.5;
                x = mix(x, x * float3(1.05, 1.08, 0.9), 0.5);
                return float4(mix(c, x, P.strength), 1.0);
            }
            """),

        BuiltInEffect(
            id: "instantFrame", displayName: "Instant Photo Frame", category: .film,
            summary: "Frames the picture in an instant-camera print border with a thicker bottom edge.",
            params: [
                .float("border", 0.06, 0, 0.15),
                .float("bottom", 0.17, 0, 0.3, label: "Bottom border"),
                .float("shadow", 0.4, 0, 1, label: "Inner shadow"),
                .color("frameColor", 0.97, 0.96, 0.92, label: "Paper")
            ],
            code: """
            \(sig) {
                float aspect = res.x / res.y;
                float2 lo = float2(P.border, P.border * aspect);
                float2 hi = float2(1.0 - P.border, 1.0 - max(P.bottom, P.border * aspect));
                float3 paper = float3(P.frameColor) * (0.97 + 0.03 * noise2(uv * res * 0.5));
                if (uv.x < lo.x || uv.y < lo.y || uv.x > hi.x || uv.y > hi.y) { return float4(paper, 1.0); }
                float2 size = max(hi - lo, float2(0.001));
                float2 inner = (uv - lo) / size;
                float innerAspect = size.x * res.x / (size.y * res.y);
                float2 s = inner;
                if (innerAspect > aspect) { s.y = 0.5 + (s.y - 0.5) * (aspect / innerAspect); }
                else { s.x = 0.5 + (s.x - 0.5) * (innerAspect / aspect); }
                float3 c = SRC(s).rgb;
                float2 e = min(inner, 1.0 - inner) * size * res;
                float edge = min(e.x, e.y);
                c *= 1.0 - P.shadow * 0.35 * (1.0 - smoothstep(0.0, res.y * 0.012, edge));
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "vhs", displayName: "VHS Tape", category: .retro,
            summary: "Home-video tape: smeared color, wobbling lines, a rolling tracking band and tape noise.",
            params: [
                .float("chromaBleed", 0.006, 0, 0.02, label: "Color smear"),
                .float("tracking", 0.4, 0, 1),
                .float("noise", 0.3, 0, 1),
                .float("wobble", 0.4, 0, 1),
                .float("saturation", 0.9, 0, 1.5)
            ],
            code: """
            \(sig) {
                float line = floor(uv.y * res.y / 2.0);
                float tick = floor(time * 30.0);
                float wob = (noise2(float2(line * 0.05, time * 4.0)) - 0.5) * 0.004 * P.wobble;
                float bandY = fract(time * 0.07);
                float band = 1.0 - smoothstep(0.0, 0.04, abs(uv.y - bandY));
                float bandShift = band * P.tracking * 0.03 * (hash21(float2(line, tick)) - 0.5);
                float2 p = float2(uv.x + wob + bandShift, uv.y);
                float3 a = SRC(p).rgb;
                float3 l = SRC(p + float2(P.chromaBleed, 0.0)).rgb;
                float3 r = SRC(p - float2(P.chromaBleed, 0.0)).rgb;
                float3 avg = (a + l + r) / 3.0;
                float3 c = float3(luma(a)) + (avg - float3(luma(avg))) * P.saturation;
                c += (hash21(float2(uv.x * res.x, line + tick * 13.0)) - 0.5) * P.noise * 0.15;
                c += band * P.tracking * 0.25 * hash21(float2(floor(uv.x * 40.0), tick));
                c = mix(c, c * float3(0.95, 1.0, 1.08) + 0.03, 0.5);
                return float4(c, 1.0);
            }
            """),

        BuiltInEffect(
            id: "dateStamp", displayName: "Date Stamp", category: .retro,
            summary: "The glowing orange date a film camera printed in the corner, like '98 7 14.",
            params: [
                .float("year", 98, 0, 99),
                .float("month", 7, 1, 12),
                .float("day", 14, 1, 31),
                .float("size", 1, 0.5, 3),
                .float("glow", 0.5, 0, 1),
                .color("color", 1.0, 0.55, 0.15)
            ],
            code: """
            inline float segBox(float2 p, float2 b) {
                float2 d = abs(p) - b;
                return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0);
            }

            inline float digitDist(float2 p, int digit) {
                int masks[10] = { 0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F };
                int m = masks[clamp(digit, 0, 9)];
                float d = 100000.0;
                if ((m & 1) != 0) { d = min(d, segBox(p - float2(0.0, 0.5), float2(0.24, 0.06))); }
                if ((m & 2) != 0) { d = min(d, segBox(p - float2(0.3, 0.25), float2(0.06, 0.22))); }
                if ((m & 4) != 0) { d = min(d, segBox(p - float2(0.3, -0.25), float2(0.06, 0.22))); }
                if ((m & 8) != 0) { d = min(d, segBox(p - float2(0.0, -0.5), float2(0.24, 0.06))); }
                if ((m & 16) != 0) { d = min(d, segBox(p - float2(-0.3, -0.25), float2(0.06, 0.22))); }
                if ((m & 32) != 0) { d = min(d, segBox(p - float2(-0.3, 0.25), float2(0.06, 0.22))); }
                if ((m & 64) != 0) { d = min(d, segBox(p, float2(0.24, 0.06))); }
                return d;
            }

            \(sig) {
                float h = res.y * 0.028 * P.size;
                float adv = 0.8;
                float2 fc = uv * res;
                float2 origin = float2(res.x * 0.93 - h * adv * 9.0, res.y * 0.93 - h);
                float2 q = (fc - origin) / h;
                float slotF = q.x / adv;
                int slot = int(floor(slotF));
                float2 lp = float2((fract(slotF) - 0.5) * adv, 0.5 - q.y);
                float d = 100000.0;
                if (q.y > -0.4 && q.y < 1.4 && slot >= 0 && slot < 9) {
                    int yr = int(P.year + 0.5);
                    int mo = int(P.month + 0.5);
                    int dy = int(P.day + 0.5);
                    int digit = -1;
                    if (slot == 1) { digit = (yr / 10) % 10; }
                    else if (slot == 2) { digit = yr % 10; }
                    else if (slot == 4) { digit = mo >= 10 ? (mo / 10) % 10 : -1; }
                    else if (slot == 5) { digit = mo % 10; }
                    else if (slot == 7) { digit = dy >= 10 ? (dy / 10) % 10 : -1; }
                    else if (slot == 8) { digit = dy % 10; }
                    if (digit >= 0) { d = digitDist(lp, digit); }
                    if (slot == 0) { d = segBox(lp - float2(0.15, 0.4), float2(0.05, 0.12)); }
                }
                float px = 1.0 / h;
                float core = 1.0 - smoothstep(0.0, px * 1.5, d);
                float halo = exp(-max(d, 0.0) * 6.0) * P.glow;
                float3 col = float3(P.color);
                float3 c = SRC(uv).rgb;
                c = mix(c, col, saturate(core * 0.95));
                c += col * halo * 0.35 * (1.0 - core);
                return float4(c, 1.0);
            }
            """)
    ]
}
// swiftlint:enable line_length
