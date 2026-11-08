import XCTest
@testable import ShadeCore

final class RecipeCodecTests: XCTestCase {
    func testDecodesFilesWrittenByShade10() throws {
        let recipe = try RecipeCodec.decode(Data(legacyFileJSON.utf8))
        XCTAssertEqual(recipe.id, UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertEqual(recipe.passes.count, 2)
        XCTAssertEqual(recipe.passes[0].effect, "posterize")
        XCTAssertEqual(recipe.passes[0].params.first?.scalar, 4)
        XCTAssertEqual(recipe.passes[1].params.map(\.name), ["gain"])
        XCTAssertTrue(recipe.passes[1].hasCustomCode)
    }

    func testRecipesWithoutFormatFieldStillDecode() throws {
        let recipe = try RecipeCodec.decode(Data(#"{"name":"x","passes":[{"effect":"invert"}]}"#.utf8))
        XCTAssertEqual(recipe.passes.first?.effect, "invert")
    }

    func testEveryPresetRoundTripsWithoutChanges() throws {
        for preset in Presets.all {
            let back = try RecipeCodec.decode(RecipeCodec.encode(preset))
            XCTAssertTrue(back.hasSameContent(as: preset), preset.name)
            XCTAssertEqual(back.id, preset.id)
        }
    }

    func testExtractsRecipeFromAMessyClaudeReply() throws {
        let reply = """
        Here's your shader!

        ```json
        {"name": "Test", "passes": [
          {"effect": "Chromatic_Aberration", "params": {"amount": 0.05}},
          {"effect": "duotone", "params": {"shadows": "#102030", "highlights": [255, 128, 0]}},
          {"code": "float4 shade(float2 uv, float2 res, float time, texture2d<float> tex, texture2d<float> orig, sampler smp, constant ShadeParams& P) { return SRC(uv) * P.gain; }",
           "params": [{"name": "gain", "value": 1.5, "min": 0, "max": 3}, {"name": "float", "value": 2}, {"name": "gain", "value": 1}]}
        ]}
        ```
        Enjoy.
        """
        let r = try RecipeCodec.extract(from: reply)
        XCTAssertEqual(r.passes[0].effect, "chromaticAberration", "aliases and punctuation in effect names resolve")
        XCTAssertEqual(r.passes[0].params.first?.scalar, 0.05)
        let highlights = try XCTUnwrap(r.passes[1].params.first { $0.name == "highlights" })
        XCTAssertEqual(highlights.value, [1, Float(128) / 255, 0], "0-255 colors are scaled")
        let shadows = try XCTUnwrap(r.passes[1].params.first { $0.name == "shadows" })
        XCTAssertEqual(shadows.value[0], Float(0x10) / 255, accuracy: 0.001, "hex colors parse")
        XCTAssertEqual(r.passes[2].params.map(\.name), ["gain", "p_float", "gain2"], "reserved and duplicate names are made safe")
    }

    func testPicksTheValidRecipeWhenTheReplyHasSeveralCodeBlocks() throws {
        let reply = "```metal\nfloat4 shade(...)\n```\nand\n```json\n{\"name\":\"B\",\"passes\":[{\"effect\":\"sepia\"}]}\n```"
        XCTAssertEqual(try RecipeCodec.extract(from: reply).name, "B")
    }

    func testRejectsNewerFormatVersions() {
        XCTAssertShadeError(.recipeUnsupportedFormat) {
            try RecipeCodec.decode(Data(#"{"format":"shade.recipe/2","name":"x","passes":[]}"#.utf8))
        }
        XCTAssertShadeError(.recipeUnsupportedFormat) {
            try RecipeCodec.decode(Data(#"{"format":"something-else","name":"x","passes":[]}"#.utf8))
        }
    }

    func testReportsWhereTheJSONIsWrong() {
        XCTAssertShadeError(.recipeInvalidJSON) { try RecipeCodec.decode(Data("{not json".utf8)) }
        XCTAssertShadeError(.recipeInvalidJSON) { try RecipeCodec.decode(Data(#"{"name":"x"}"#.utf8)) }
        XCTAssertShadeError(.recipeInvalidJSON) { try RecipeCodec.extract(from: "no recipe here") }
        XCTAssertShadeError(.recipeInvalidJSON) {
            try RecipeCodec.decode(Data(#"{"name":"x","passes":[{"effect":"posterize","params":{"levels":"lots"}}]}"#.utf8))
        }
    }

    func testRejectsUnknownEffectsAndCodeWithoutShadeFunction() {
        XCTAssertShadeError(.recipeInvalid) { try RecipeCodec.decode(Data(#"{"name":"x","passes":[{"effect":"warpDrive"}]}"#.utf8)) }
        XCTAssertShadeError(.recipeInvalid) { try RecipeCodec.decode(Data(#"{"name":"x","passes":[{"code":"float4 main() {}"}]}"#.utf8)) }
        XCTAssertShadeError(.recipeInvalid) { try RecipeCodec.decode(Data(#"{"name":"x","passes":[{}]}"#.utf8)) }
    }

    func testEnforcesSizeLimits() {
        let tooManyPasses = "{\"name\":\"x\",\"passes\":[" + Array(repeating: "{\"effect\":\"invert\"}", count: RecipeLimits.maxPasses + 1).joined(separator: ",") + "]}"
        XCTAssertShadeError(.recipeInvalid) { try RecipeCodec.decode(Data(tooManyPasses.utf8)) }

        let longCode = String(repeating: "x", count: RecipeLimits.maxCodeCharacters) + " shade"
        let tooMuchCode = "{\"name\":\"x\",\"passes\":[{\"code\":\(jsonString(longCode))}]}"
        XCTAssertShadeError(.recipeInvalid) { try RecipeCodec.decode(Data(tooMuchCode.utf8)) }

        XCTAssertShadeError(.recipeTooLarge) { try RecipeCodec.decode(Data(count: RecipeLimits.maxInputBytes + 1)) }
        XCTAssertShadeError(.recipeTooLarge) { try RecipeCodec.extract(from: String(repeating: " ", count: RecipeLimits.maxInputBytes + 1)) }
    }

    func testCleansNamesAndClampsValues() throws {
        let json = #"{"name":"  Neon\u0000\nNight  ","passes":[{"effect":"pixelate","params":{"size":120}},{"effect":"invert","mix":7},{"code":"float4 shade() {}","params":[{"name":"k","value":5,"min":0,"max":1}]}]}"#
        let r = try RecipeCodec.decode(Data(json.utf8))
        XCTAssertEqual(r.name, "Neon  Night")
        XCTAssertEqual(r.passes[0].params[0].scalar, 120, "a built-in value outside the default slider range is kept")
        XCTAssertGreaterThanOrEqual(r.passes[0].params[0].max, 120, "and the slider range widens to include it")
        XCTAssertEqual(r.passes[1].mix, 1, "mix is clamped to 0...1")
        XCTAssertEqual(r.passes[2].params[0].scalar, 1, "explicit ranges clamp values")
        let blank = try RecipeCodec.decode(Data(#"{"name":"   ","passes":[]}"#.utf8))
        XCTAssertEqual(blank.name, "Untitled")
    }

    func testEncodingIsDeterministic() throws {
        let preset = Presets.all[2]
        XCTAssertEqual(try RecipeCodec.encode(preset), try RecipeCodec.encode(preset))
    }
}
