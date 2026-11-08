import Foundation

/// Builds complete Metal Shading Language source for a pass.
///
/// Every pass, built-in or custom, is a function with this exact signature:
///
///     float4 shade(float2 uv, float2 res, float time,
///                  texture2d<float> tex, texture2d<float> orig,
///                  sampler smp, constant ShadeParams& P)
///
/// The app wraps it with a prelude (helpers + a generated `ShadeParams` struct) and an entry point,
/// then compiles it on the device at runtime with `MTLDevice.makeLibrary(source:)`.
public enum ShaderSource {
    public static let signature = "float4 shade(float2 uv, float2 res, float time, texture2d<float> tex, texture2d<float> orig, sampler smp, constant ShadeParams& P)"

    public static let vertexFunctionName = "shade_vertex"
    public static let fragmentFunctionName = "shade_fragment"

    /// Helpers that every pass (and Claude-written code) can use.
    public static let helpers = """
    #define SRC(p) tex.sample(smp, (p))
    #define ORIG(p) orig.sample(smp, (p))
    #define PI 3.14159265359
    #define TAU 6.28318530718

    inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    inline float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    inline float2 hash22(float2 p) {
        float n = hash21(p);
        return float2(n, hash21(p + n + 17.17));
    }

    inline float noise2(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    inline float fbm(float2 p) {
        float v = 0.0;
        float a = 0.5;
        for (int i = 0; i < 5; i++) {
            v += a * noise2(p);
            p = p * 2.03 + float2(17.0, 9.0);
            a *= 0.5;
        }
        return v;
    }

    inline float3 rgb2hsv(float3 c) {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        float4 p = mix(float4(c.b, c.g, K.w, K.z), float4(c.g, c.b, K.x, K.y), step(c.b, c.g));
        float4 q = mix(float4(p.x, p.y, p.w, c.r), float4(c.r, p.y, p.z, p.x), step(p.x, c.r));
        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }

    inline float3 hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(float3(c.x) + K.xyz) * 6.0 - float3(K.w));
        return c.z * mix(float3(K.x), saturate(p - float3(K.x)), c.y);
    }

    inline float sobel(texture2d<float> t, sampler s, float2 uv, float2 px) {
        float tl = luma(t.sample(s, uv + px * float2(-1.0, -1.0)).rgb);
        float tc = luma(t.sample(s, uv + px * float2( 0.0, -1.0)).rgb);
        float tr = luma(t.sample(s, uv + px * float2( 1.0, -1.0)).rgb);
        float ml = luma(t.sample(s, uv + px * float2(-1.0,  0.0)).rgb);
        float mr = luma(t.sample(s, uv + px * float2( 1.0,  0.0)).rgb);
        float bl = luma(t.sample(s, uv + px * float2(-1.0,  1.0)).rgb);
        float bc = luma(t.sample(s, uv + px * float2( 0.0,  1.0)).rgb);
        float br = luma(t.sample(s, uv + px * float2( 1.0,  1.0)).rgb);
        float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
        float gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;
        return length(float2(gx, gy));
    }

    inline float3 gradient5(float t, float3 c0, float3 c1, float3 c2, float3 c3, float3 c4) {
        float x = saturate(t) * 4.0;
        if (x < 1.0) return mix(c0, c1, x);
        if (x < 2.0) return mix(c1, c2, x - 1.0);
        if (x < 3.0) return mix(c2, c3, x - 2.0);
        return mix(c3, c4, x - 3.0);
    }
    """

    public static let header = """
    #include <metal_stdlib>
    using namespace metal;

    struct ShadeVOut {
        float4 position [[position]];
        float2 uv;
    };

    struct ShadeSystem {
        float2 resolution;
        float time;
        float mixAmount;
    };
    """

    public static let entryPoints = """
    vertex ShadeVOut shade_vertex(uint vid [[vertex_id]]) {
        float2 pos = float2(float((vid << 1) & 2u), float(vid & 2u));
        ShadeVOut o;
        o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(pos.x, 1.0 - pos.y);
        return o;
    }

    fragment float4 shade_fragment(ShadeVOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant ShadeSystem& sys [[buffer(0)]],
                                   constant ShadeParams& P [[buffer(1)]]) {
        constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 before = tex.sample(smp, in.uv);
        float4 after = shade(in.uv, sys.resolution, sys.time, tex, orig, smp, P);
        float3 rgb = mix(before.rgb, after.rgb, sys.mixAmount);
        rgb = select(rgb, float3(0.0), isnan(rgb));
        return float4(saturate(rgb), 1.0);
    }
    """

    public static func paramsStruct(_ params: [ShaderParam]) -> String {
        var lines = ["struct ShadeParams {"]
        if params.isEmpty { lines.append("    float _unused;") }
        for p in params {
            lines.append("    \(p.kind == .color ? "packed_float3" : "float") \(p.name);")
        }
        lines.append("};")
        return lines.joined(separator: "\n")
    }

    /// The `shade` function body for a pass (built-in or custom), or nil if the pass has nothing to run.
    public static func userCode(for pass: ShaderPass) -> String? {
        if let fx = pass.builtInEffect { return fx.code }
        if let code = pass.code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return code }
        return nil
    }

    /// Complete, compilable MSL for one pass. Errors inside the pass code are reported as `shade:<line>:<col>`.
    public static func source(for pass: ShaderPass) -> String? {
        guard let code = userCode(for: pass) else { return nil }
        return [
            header,
            paramsStruct(pass.params),
            "#line 1 \"helpers\"",
            helpers,
            "#line 1 \"shade\"",
            code,
            "#line 1 \"entry\"",
            entryPoints,
            ""
        ].joined(separator: "\n")
    }

    /// Parameter values flattened in struct order (matches `ShadeParams` memory layout: all 4-byte floats).
    public static func floats(for pass: ShaderPass) -> [Float] {
        let values = pass.params.flatMap { p in p.kind == .color ? Array(p.value.prefix(3)) : [p.scalar] }
        return values.isEmpty ? [0] : values
    }
}
