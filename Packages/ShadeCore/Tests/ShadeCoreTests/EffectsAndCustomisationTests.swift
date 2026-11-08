import XCTest
@testable import ShadeCore

final class EffectCatalogTests: XCTestCase {
    func testEffectIDsAreUniqueAndAliasesResolve() {
        let ids = BuiltInEffects.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids.map(BuiltInEffects.normalizedKey)).count, "ids must stay unique after normalization")
        for (alias, target) in BuiltInEffects.aliases {
            XCTAssertNotNil(BuiltInEffects.all.first { $0.id == target }, "alias \(alias) points at missing \(target)")
            XCTAssertNil(BuiltInEffects.all.first { BuiltInEffects.normalizedKey($0.id) == alias }, "alias \(alias) shadows a real id")
        }
    }

    func testEveryCategoryHasEffectsAndEveryEffectIsDescribed() {
        for category in EffectCategory.allCases {
            XCTAssertFalse(BuiltInEffects.inCategory(category).isEmpty, category.rawValue)
        }
        for fx in BuiltInEffects.all {
            XCTAssertFalse(fx.summary.isEmpty, fx.id)
            XCTAssertLessThanOrEqual(fx.params.count, RecipeLimits.maxParamsPerPass, fx.id)
            XCTAssertEqual(Set(fx.params.map(\.name)).count, fx.params.count, "duplicate param in \(fx.id)")
        }
    }

    func testOnlyTrailsReadsItsPreviousFrame() {
        XCTAssertEqual(BuiltInEffects.all.filter(\.usesHistory).map(\.id), ["trails"])
        XCTAssertTrue(ShaderPass(effect: "trails").usesHistory)
        XCTAssertFalse(ShaderPass(effect: "bloom").usesHistory)
    }

    func testNewEffectsAreReachableByEverydayNames() {
        XCTAssertEqual(BuiltInEffects.find("Polaroid")?.id, "instantFrame")
        XCTAssertEqual(BuiltInEffects.find("light leaks")?.id, "lightLeak")
        XCTAssertEqual(BuiltInEffects.find("VHS")?.id, "vhs")
        XCTAssertEqual(BuiltInEffects.find("soft glow")?.id, "orton")
    }
}

final class PresetTests: XCTestCase {
    func testPresetsAreValidUniqueAndCategorised() throws {
        XCTAssertEqual(Presets.all.count, Set(Presets.all.map(\.id)).count, "preset ids are unique")
        XCTAssertEqual(Presets.all.count, Set(Presets.all.map(\.name)).count, "preset names are unique")
        for preset in Presets.all {
            XCTAssertEqual(try RecipeValidator.validate(preset).passes.count, preset.passes.count, preset.name)
            XCTAssertNotNil(Presets.category(of: preset.id), preset.name)
        }
        XCTAssertGreaterThanOrEqual(Presets.sections.first { $0.category == .nostalgic }?.recipes.count ?? 0, 6)
        XCTAssertGreaterThanOrEqual(Presets.sections.first { $0.category == .dreamy }?.recipes.count ?? 0, 8)
    }

    func testPresetIDsFromVersion10AreKept() {
        // Saved sessions refer to presets by id; these existed in 1.0 and must keep their ids and names.
        let expected = [1: "Original", 2: "Comic Book", 3: "Neon Edges", 4: "Retro CRT", 5: "Film Noir", 6: "Pocket Console",
                        7: "Dreamy", 8: "Oil Painting", 9: "Pencil Sketch", 10: "Thermal", 11: "Vaporwave", 12: "Underwater", 13: "Night Vision"]
        for (n, name) in expected {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
            XCTAssertEqual(Presets.find(id)?.name, name)
        }
    }
}

final class RecipeFieldTests: XCTestCase {
    func testIntensityIsOptionalClampedAndRoundTrips() throws {
        let plain = try RecipeCodec.decode(Data(#"{"name":"x","passes":[{"effect":"sepia"}]}"#.utf8))
        XCTAssertEqual(plain.intensity, 1)
        XCTAssertFalse(String(decoding: try RecipeCodec.encode(plain), as: UTF8.self).contains("intensity"),
                       "full intensity is not written, so files stay identical to 1.0")

        let half = try RecipeCodec.decode(Data(#"{"name":"x","intensity":0.4,"passes":[{"effect":"sepia"}]}"#.utf8))
        XCTAssertEqual(half.intensity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(try RecipeCodec.decode(RecipeCodec.encode(half)).intensity, 0.4, accuracy: 0.0001)

        XCTAssertEqual(try RecipeCodec.decode(Data(#"{"name":"x","intensity":7,"passes":[]}"#.utf8)).intensity, 1)
        XCTAssertEqual(try RecipeCodec.decode(Data(#"{"name":"x","intensity":-2,"passes":[]}"#.utf8)).intensity, 0)
    }

    func testHistoryFlagIsKeptForCustomCodeOnly() throws {
        let json = #"{"name":"x","passes":[{"code":"float4 shade() {}","history":true},{"effect":"sepia","history":true}]}"#
        let r = try RecipeCodec.decode(Data(json.utf8))
        XCTAssertTrue(r.passes[0].usesHistory)
        XCTAssertFalse(r.passes[1].usesHistory, "built-ins can't be switched into feedback mode")
        let back = try RecipeCodec.decode(RecipeCodec.encode(r))
        XCTAssertTrue(back.passes[0].history)
    }

    func testOldVignettesGainAMovableCenter() throws {
        let r = try RecipeCodec.decode(Data(#"{"name":"x","passes":[{"effect":"vignette","params":{"strength":0.9}}]}"#.utf8))
        let names = r.passes[0].params.map(\.name)
        XCTAssertTrue(names.contains("centerX") && names.contains("centerY"))
        XCTAssertEqual(r.passes[0].params.first { $0.name == "strength" }?.scalar, 0.9)
    }

    func testTapToFocusMovesOnlyFocusParams() {
        var recipe = ShaderRecipe(name: "x", passes: [.builtIn("tiltShift"), .builtIn("zoomBlur"), .builtIn("bloom")])
        XCTAssertTrue(recipe.hasFocusPoint)
        XCTAssertTrue(recipe.setFocus(x: 0.2, y: 0.8))
        XCTAssertEqual(recipe.passes[0].params.first { $0.name == "centerY" }?.scalar, 0.8)
        XCTAssertEqual(recipe.passes[1].params.first { $0.name == "centerX" }?.scalar, 0.2)

        var noFocus = ShaderRecipe(name: "y", passes: [.builtIn("bloom")])
        let before = noFocus
        XCTAssertFalse(noFocus.setFocus(x: 0.1, y: 0.1))
        XCTAssertTrue(noFocus.hasSameContent(as: before))
    }
}

/// Deterministic generator so randomness tests are repeatable.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class VariationTests: XCTestCase {
    func testRandomizeStaysInRangeAndKeepsFocus() {
        var rng = SeededGenerator(state: 42)
        var pass = ShaderPass.builtIn("zoomBlur", ["centerX": [0.1], "centerY": [0.9]])
        for _ in 0..<50 {
            pass = pass.randomized(using: &rng)
            for p in pass.params where p.kind == .float { XCTAssertTrue((p.min...p.max).contains(p.scalar), p.name) }
            XCTAssertEqual(pass.params.first { $0.name == "centerX" }?.scalar, 0.1)
            XCTAssertEqual(pass.params.first { $0.name == "centerY" }?.scalar, 0.9)
        }
    }

    func testRemixNudgesWithoutDarkeningColors() {
        var rng = SeededGenerator(state: 7)
        let base = ShaderRecipe(name: "x", passes: [.builtIn("splitTone", ["highlights": [1, 1, 1]])])
        for _ in 0..<50 {
            let remixed = base.remixed(amount: 0.2, using: &rng)
            let highlights = remixed.passes[0].params.first { $0.name == "highlights" }!.value
            XCTAssertTrue(highlights.allSatisfy { $0 >= 0.79 }, "a channel above 1 must be clamped, not read as 0-255: \(highlights)")
        }
        XCTAssertTrue(base.remixed(amount: 0, using: &rng).hasSameContent(as: base))
    }

    func testResetRestoresBuiltInDefaultsOnly() {
        let changed = ShaderPass.builtIn("bloom", ["intensity": [3.5]], mix: 0.5)
        let reset = changed.resetToDefaults()!
        XCTAssertEqual(reset.params.first { $0.name == "intensity" }?.scalar, 1.2)
        XCTAssertEqual(reset.mix, 0.5, "mix and enabled are the user's, not the effect's")
        XCTAssertEqual(reset.id, changed.id)
        XCTAssertNil(ShaderPass(code: "float4 shade() {}").resetToDefaults())
    }
}
