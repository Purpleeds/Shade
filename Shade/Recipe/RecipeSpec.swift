import Foundation

/// The instructions that teach Claude how to write Shade recipes.
/// Used as the system prompt for in-app generation and as the copy-paste prompt for claude.ai.
enum RecipeSpec {
    static var effectCatalog: String {
        BuiltInEffects.all.map { fx in
            let params = fx.params.map { p -> String in
                switch p.kind {
                case .float: return "\(p.name) (\(fmt(p.min))...\(fmt(p.max)), default \(fmt(p.scalar)))"
                case .color: return "\(p.name) (color, default \(hex(p.value)))"
                }
            }
            let paramText = params.isEmpty ? "no params" : params.joined(separator: ", ")
            return "- `\(fx.id)`: \(fx.summary) Params: \(paramText)."
        }.joined(separator: "\n")
    }

    /// Hand-written so it reads well; Tools/ShaderCheck verifies that it parses and compiles.
    static let exampleRecipe = #"""
    {
      "format": "shade.recipe/1",
      "name": "Neon Comic",
      "description": "Flat comic colors with glowing, color-cycling outlines.",
      "author": "Claude",
      "passes": [
        { "effect": "colorGrade", "params": { "saturation": 1.3, "contrast": 1.1, "tint": "#FFF2E0" } },
        { "effect": "posterize", "params": { "levels": 5 } },
        {
          "name": "Glow outlines",
          "code": "float4 shade(float2 uv, float2 res, float time, texture2d<float> tex, texture2d<float> orig, sampler smp, constant ShadeParams& P) {\n    float e = sobel(tex, smp, uv, float2(P.width) / res);\n    float hue = fract(uv.y * 0.5 + time * P.speed);\n    float3 neon = hsv2rgb(float3(hue, 0.85, 1.0));\n    float glow = smoothstep(0.1, 0.6, e) * P.glow;\n    return float4(SRC(uv).rgb + neon * glow, 1.0);\n}",
          "params": [
            { "name": "width", "type": "float", "value": 1.5, "min": 0.5, "max": 4, "label": "Line width" },
            { "name": "speed", "type": "float", "value": 0.1, "min": 0, "max": 1 },
            { "name": "glow", "type": "float", "value": 1.2, "min": 0, "max": 4 }
          ]
        },
        { "effect": "vignette", "params": { "strength": 0.5 }, "mix": 0.8 }
      ]
    }
    """#

    static var specification: String {
        """
        # Shade recipe format (shade.recipe/1)

        Shade is an iPhone app that runs a stack of real-time GPU shader passes over the live camera feed \
        (portrait, roughly 1080x1920, 30 fps, iPhone GPU). A *recipe* is a JSON object describing that stack. \
        Each pass reads the previous pass's output; the first pass reads the camera image.

        ## JSON schema

        ```
        {
          "format": "shade.recipe/1",
          "name": "Short name",
          "description": "One sentence about the look",
          "author": "Claude",
          "passes": [ PASS, PASS, ... ]          // 1 to 8 passes, run in order
        }
        ```

        A PASS is either a built-in effect:

        ```
        { "effect": "<effect id>", "params": { "<param>": <number or [r,g,b] or "#RRGGBB"> }, "mix": 1.0 }
        ```

        or custom Metal code:

        ```
        {
          "name": "Readable name",
          "code": "<Metal Shading Language source defining the shade function>",
          "params": [
            { "name": "strength", "type": "float", "value": 0.5, "min": 0, "max": 1, "label": "Strength" },
            { "name": "tint", "type": "color", "value": [1.0, 0.5, 0.2] }
          ],
          "mix": 1.0
        }
        ```

        - `mix` (optional, 0...1) blends the pass result with its input. Omitted means 1.
        - Built-in params you leave out keep their defaults. Colors are linear 0...1 RGB triples or "#RRGGBB".
        - Every param becomes a live slider / color picker in the app, so expose the values a person would want to tweak.

        ## Built-in effects

        \(effectCatalog)

        ## Custom Metal code

        `code` must define exactly this function (Metal Shading Language, C++14-based):

        ```metal
        \(ShaderSource.signature) {
            ...
            return float4(rgb, 1.0);
        }
        ```

        - `uv`: 0...1 texture coordinate, origin at the TOP-LEFT of the screen. `res`: frame size in pixels. `time`: seconds since start (use it for animation).
        - `tex`: output of the previous pass (or the camera for the first pass). `orig`: the untouched camera frame.
        - Sample with `SRC(p)` (= `tex.sample(smp, p)`) and `ORIG(p)` (= `orig.sample(smp, p)`). Sampling clamps at the edges and is bilinear.
        - Params: each param `foo` is `P.foo`. Floats are `float`; colors are `packed_float3`, so write `float3(P.tint)`.
        - Available helpers: `luma(float3)`, `hash21(float2)`, `hash22(float2)`, `noise2(float2)` (value noise 0..1), `fbm(float2)` (5 octaves), \
        `rgb2hsv(float3)`, `hsv2rgb(float3)`, `sobel(tex, smp, uv, float2 pixelStep)` (edge strength, ~0..4), \
        `gradient5(t, c0, c1, c2, c3, c4)` (5-stop gradient), constants `PI`, `TAU`.
        - You may define extra `inline` helper functions above `shade` inside the same `code` string. Do not redefine the helpers above or `ShadeParams`.
        - Use `float` / `float2` / `float3` / `float4` (not `vec3`, `mix` exists, `fract` exists, `atan2(y, x)`, `fmod`). \
        Write float literals with a decimal point (`1.0`, not `1`) and construct vectors explicitly (`float3(0.0)`).
        - No texture writes, no `#include`, no buffers, no `discard`. Keep loops bounded by constants (at most ~64 texture samples per pixel) so it stays real-time.
        - Output is clamped to 0...1; alpha is ignored.
        - Inside the JSON string, escape newlines as `\\n` and quotes as `\\"` (standard JSON).

        ## How to design a good recipe

        - Prefer built-in effects for standard operations (grading, outlines, posterize, grain, bloom, vignette...). Use custom code for the \
        signature part of the look that no built-in covers (stylised lighting, patterns, procedural textures, distortions, special color mapping).
        - Match the reference closely: its palette (use `paletteMap`, `duotone` or `colorGrade` tint/temperature), contrast, saturation, \
        line work, texture (grain, halftone, paper, scanlines), blur/glow and any animation implied by a video.
        - The look must work on arbitrary live camera footage, not just the reference image. Do not try to reproduce the reference content.
        - Keep it to 2-6 passes. Name params clearly and give sensible min/max ranges.

        ## Example

        ```json
        \(exampleRecipe)
        ```
        """
    }

    /// System prompt for the in-app Claude call.
    static var systemPrompt: String {
        """
        You are the shader designer inside Shade, an iPhone camera app. The user shows you reference images \
        (or frames from a video, in order) and you design a real-time camera shader recipe that reproduces their visual style.

        \(specification)

        ## Response format

        First write 1-3 sentences describing the style you identified. Then output the complete recipe as a single \
        ```json fenced code block. Output nothing after the code block. If you are asked to fix compile errors, \
        reply with the complete corrected recipe in the same format.
        """
    }

    /// Prompt to paste into claude.ai together with an image or video.
    static var chatPrompt: String {
        """
        I use an iPhone app called Shade that applies real-time GPU shaders to my camera. I'm attaching an image \
        (or video) whose visual style I want to recreate on live camera footage. Study the style (palette, contrast, \
        lighting, line work, textures, distortion, and motion if it's a video) and design a Shade recipe for it.

        Reply with a short description of the style, then the complete recipe as one ```json code block that follows \
        the format below exactly. I will paste your reply straight into the app.

        \(specification)
        """
    }

    private static func fmt(_ v: Float) -> String {
        if v == v.rounded() && abs(v) < 100_000 { return String(Int(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    private static func hex(_ v: [Float]) -> String {
        let c = v.map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c[0], c[1], c[2])
    }
}
