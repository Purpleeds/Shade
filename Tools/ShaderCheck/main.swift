import Foundation

// Shader check tool.
//
//   swiftc Shade/Recipe/*.swift Tools/ShaderCheck/main.swift -o shadercheck
//   ./shadercheck <output-dir> [example.shade ...]
//
// - Writes the full Metal source of every built-in effect, preset pass and example pass to <output-dir>/*.metal
//   so CI can compile them with `xcrun metal` (the app compiles them at runtime on the phone).
// - Round-trips every recipe through JSON to make sure the format is stable.
// - Writes <output-dir>/PROMPT.md, the copy-paste prompt for claude.ai.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: shadercheck <output-dir> [recipe files...]") }
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var written = 0
func emit(_ label: String, _ pass: ShaderPass) {
    if let problem = pass.structuralProblem { fail("\(label): \(problem)") }
    guard let source = ShaderSource.source(for: pass) else { fail("\(label): no source") }
    let safe = label.map { $0.isLetter || $0.isNumber ? $0 : "_" }
    let url = outDir.appendingPathComponent(String(safe) + ".metal")
    do { try source.write(to: url, atomically: true, encoding: .utf8) } catch { fail("\(label): \(error)") }
    written += 1
}

func roundTrip(_ recipe: ShaderRecipe, _ label: String) {
    let data = recipe.jsonData()
    guard let back = try? ShaderRecipe.decode(data) else { fail("\(label): JSON round trip failed\n\(recipe.jsonString)") }
    guard back.passes.count == recipe.passes.count else { fail("\(label): pass count changed in round trip") }
    for (a, b) in zip(recipe.passes, back.passes) {
        if a.params.map(\.value) != b.params.map(\.value) || a.params.map(\.name) != b.params.map(\.name) {
            fail("\(label): params changed in round trip (\(a.displayName))")
        }
        if a.code != b.code || a.effect != b.effect { fail("\(label): pass changed in round trip") }
    }
    let problems = recipe.structuralProblems
    if !problems.isEmpty { fail("\(label): \(problems.joined(separator: "; "))") }
}

for fx in BuiltInEffects.all {
    emit("builtin_\(fx.id)", ShaderPass(effect: fx.id))
    if ShaderPass(effect: fx.id).builtInEffect?.id != fx.id { fail("effect lookup broken for \(fx.id)") }
}

for (i, recipe) in Presets.all.enumerated() {
    roundTrip(recipe, "preset \(recipe.name)")
    for (j, pass) in recipe.passes.enumerated() where pass.isCustom {
        emit("preset_\(i)_\(j)", pass)
    }
}

do {
    let example = try ShaderRecipe.extract(from: RecipeSpec.exampleRecipe)
    guard example.passes.count == 4 else { fail("spec example: wrong pass count") }
    roundTrip(example, "spec example")
    for (j, pass) in example.passes.enumerated() where pass.isCustom { emit("spec_example_\(j)", pass) }
} catch {
    fail("spec example: \(error.localizedDescription)")
}

// Parsing robustness: shorthand params, hex colors, aliases, text around the JSON.
let messy = """
Here's your shader!

```json
{"name": "Test", "passes": [
  {"effect": "Chromatic_Aberration", "params": {"amount": 0.05}},
  {"effect": "duotone", "params": {"shadows": "#102030", "highlights": [255, 128, 0]}},
  {"code": "float4 shade(float2 uv, float2 res, float time, texture2d<float> tex, texture2d<float> orig, sampler smp, constant ShadeParams& P) { return SRC(uv) * P.gain; }",
   "params": [{"name": "gain", "value": 1.5, "min": 0, "max": 3}, {"name": "float", "value": 2}]}
]}
```
Enjoy.
"""
do {
    let r = try ShaderRecipe.extract(from: messy)
    guard r.passes.count == 3 else { fail("messy parse: wrong pass count") }
    guard r.passes[0].effect == "chromaticAberration", r.passes[0].params.first?.scalar == 0.05 else { fail("messy parse: alias/params") }
    guard r.passes[1].params.first(where: { $0.name == "highlights" })?.value == [1, Float(128) / 255, 0] else { fail("messy parse: 0-255 color") }
    guard abs((r.passes[1].params.first(where: { $0.name == "shadows" })?.value[0] ?? 0) - Float(0x10) / 255) < 0.001 else { fail("messy parse: hex color") }
    guard r.passes[2].params.map(\.name) == ["gain", "p_float"] else { fail("messy parse: identifier sanitising \(r.passes[2].params.map(\.name))") }
    emit("parse_test", r.passes[2])
    roundTrip(r, "messy")
} catch {
    fail("messy parse: \(error.localizedDescription)")
}

for path in args.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { fail("cannot read \(path)") }
    do {
        let recipe = try ShaderRecipe.extract(from: String(decoding: data, as: UTF8.self))
        roundTrip(recipe, path)
        for (j, pass) in recipe.passes.enumerated() {
            emit("example_\(url.deletingPathExtension().lastPathComponent)_\(j)", pass)
        }
    } catch {
        fail("\(path): \(error.localizedDescription)")
    }
}

let promptHeader = """
<!-- Generated by Tools/ShaderCheck from Shade/Recipe/RecipeSpec.swift. The app's "Copy prompt" button copies the same text. -->

# Prompt for creating Shade shaders in Claude chat

1. Open [claude.ai](https://claude.ai) (or the Claude app) and start a new chat.
2. Attach the image or video whose style you want.
3. Paste everything below the line as your message and send it.
4. Copy Claude's whole reply and, in Shade, tap **Create → Paste from clipboard**.

---


"""
try (promptHeader + RecipeSpec.chatPrompt + "\n").write(to: outDir.appendingPathComponent("PROMPT.md"), atomically: true, encoding: .utf8)
try (RecipeSpec.systemPrompt + "\n").write(to: outDir.appendingPathComponent("system-prompt.txt"), atomically: true, encoding: .utf8)

print("Wrote \(written) Metal sources and PROMPT.md to \(outDir.path)")
