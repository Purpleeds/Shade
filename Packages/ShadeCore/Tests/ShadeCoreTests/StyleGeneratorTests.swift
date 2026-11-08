import XCTest
@testable import ShadeCore

/// Plays back scripted Claude replies and records every request.
final class ScriptedClaude: ClaudeMessaging, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private(set) var requests: [MessagesRequest] = []

    init(_ replies: [String]) { self.replies = replies }

    func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        let text: String = lock.locked {
            requests.append(request)
            return replies.isEmpty ? "no more replies" : replies.removeFirst()
        }
        return MessagesResponse(id: "msg", content: [.object(["type": .string("text"), "text": .string(text)])], stopReason: "end_turn")
    }
}

/// Fails compilation for passes whose code contains "BROKEN".
struct FakeCompiler: ShaderCompiling {
    func compileProblems(for recipe: ShaderRecipe) async -> [String] {
        recipe.passes.enumerated().compactMap { i, pass in
            (pass.code ?? "").contains("BROKEN") ? "Pass \(i + 1): shade:1:1: error: use of undeclared identifier 'BROKEN'" : nil
        }
    }
}

final class StyleGeneratorTests: XCTestCase {
    let settings = GenerationSettings(model: "claude-opus-5-5", effort: "high")
    let image = Data(repeating: 0xFF, count: 1000)

    func reply(code: String) -> String {
        "A neon look.\n\n```json\n{\"name\":\"Neon\",\"passes\":[{\"effect\":\"posterize\"},{\"code\":\(jsonString("float4 shade(float2 uv, float2 res, float time, texture2d<float> tex, texture2d<float> orig, sampler smp, constant ShadeParams& P) { \(code) }"))}]}\n```"
    }

    func testFirstGoodReplyIsReturnedWithItsExplanation() async throws {
        let claude = ScriptedClaude([reply(code: "return SRC(uv);")])
        let result = try await StyleGenerator(client: claude, compiler: FakeCompiler(), settings: settings)
            .generate(GenerationRequest(images: [image]))
        XCTAssertEqual(result.attempts, 1)
        XCTAssertEqual(result.recipe.name, "Neon")
        XCTAssertEqual(result.recipe.author, "Claude")
        XCTAssertEqual(result.explanation, "A neon look.")
        let sent = try XCTUnwrap(claude.requests.first)
        XCTAssertEqual(sent.model, "claude-opus-5-5")
        XCTAssertEqual(sent.effort, "high")
        XCTAssertEqual(sent.fallbacks, "default")
        XCTAssertEqual(sent.messages[0].content.count, 2, "image + instruction")
        XCTAssertEqual(sent.messages[0].content[0]["type"]?.stringValue, "image")
    }

    func testCompileErrorsAreSentBackAndTheFixIsUsed() async throws {
        let claude = ScriptedClaude([reply(code: "return BROKEN;"), reply(code: "return SRC(uv);")])
        let result = try await StyleGenerator(client: claude, compiler: FakeCompiler(), settings: settings)
            .generate(GenerationRequest(images: [image]))
        XCTAssertEqual(result.attempts, 2)
        let second = claude.requests[1].messages
        XCTAssertEqual(second.map(\.role), [.user, .assistant, .user], "same conversation, assistant turn replayed")
        let feedback = second[2].content[0]["text"]?.stringValue ?? ""
        XCTAssertTrue(feedback.contains("undeclared identifier 'BROKEN'"), feedback)
    }

    func testUnparseableRepliesAreRetriedThenFailClearly() async throws {
        let claude = ScriptedClaude(["no json", "still none", "nope"])
        let generator = StyleGenerator(client: claude, compiler: FakeCompiler(), settings: settings, maxFixAttempts: 2)
        await assertShadeErrorAsync(.generationFailed) { try await generator.generate(GenerationRequest(images: [self.image])) }
        XCTAssertEqual(claude.requests.count, 3)
    }

    func testRejectsEmptyAndOversizedRequestsWithoutCallingClaude() async throws {
        let claude = ScriptedClaude([])
        let generator = StyleGenerator(client: claude, compiler: FakeCompiler(), settings: settings)
        await assertShadeErrorAsync(.generationInvalidInput) { try await generator.generate(GenerationRequest(images: [], notes: "  ")) }
        await assertShadeErrorAsync(.generationInvalidInput) {
            try await generator.generate(GenerationRequest(images: Array(repeating: self.image, count: 9)))
        }
        await assertShadeErrorAsync(.generationInvalidInput) {
            try await generator.generate(GenerationRequest(images: [Data(count: GenerationRequest.maxImageBytes + 1)]))
        }
        XCTAssertTrue(claude.requests.isEmpty)
    }

    func testModelsWithoutServerFallbackDontAskForIt() async throws {
        let claude = ScriptedClaude([reply(code: "return SRC(uv);")])
        _ = try await StyleGenerator(client: claude, compiler: FakeCompiler(), settings: GenerationSettings(model: "claude-haiku-5-5", effort: "low"))
            .generate(GenerationRequest(images: [], notes: "film noir"))
        XCTAssertNil(claude.requests[0].fallbacks)
    }

    func testUnknownSettingsFallBackToDefaults() {
        let s = GenerationSettings(model: "gpt-9", effort: "ludicrous")
        XCTAssertEqual(s.model.id, GenerationSettings.defaultModel)
        XCTAssertEqual(s.effort, GenerationSettings.defaultEffort)
    }
}

final class StyleAnalysisTests: XCTestCase {
    func image(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8), size: Int = 64) throws -> RGBAImage {
        var bytes: [UInt8] = []
        for y in 0..<size { for x in 0..<size { let p = pixel(x, y); bytes += [p.0, p.1, p.2, 255] } }
        return try RGBAImage(width: size, height: size, bytes: bytes)
    }

    func testMonochromeImagesGetADuotone() throws {
        let gray = try image { x, _ in let v = UInt8(x * 4); return (v, v, v) }
        let recipe = try StyleAnalyzer.recipe(from: gray)
        XCTAssertTrue(recipe.passes.contains { $0.effect == "duotone" })
        XCTAssertTrue(RecipeValidator.problems(in: recipe).isEmpty)
    }

    func testFlatColorArtGetsPosterized() throws {
        let flat = try image { x, y in (x < 32) == (y < 32) ? (230, 40, 60) : (30, 60, 200) }
        let recipe = try StyleAnalyzer.recipe(from: flat)
        XCTAssertTrue(recipe.passes.contains { $0.effect == "posterize" })
        XCTAssertTrue(recipe.passes.contains { $0.effect == "paletteMap" })
    }

    func testRejectsDamagedBitmaps() {
        XCTAssertShadeError(.generationInvalidInput) { try RGBAImage(width: 10, height: 10, bytes: [1, 2, 3]) }
    }
}
