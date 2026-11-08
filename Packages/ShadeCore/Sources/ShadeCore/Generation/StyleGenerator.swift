import Foundation

/// Compiles recipes on the real GPU compiler. Implemented by the app with Metal; tests use a fake.
public protocol ShaderCompiling: Sendable {
    /// Returns one readable message per pass that fails to compile (empty = everything compiles).
    func compileProblems(for recipe: ShaderRecipe) async -> [String]
}

/// What the person gave us to work from.
public struct GenerationRequest: Sendable {
    public var images: [Data]          // JPEG data, already downscaled
    public var videoFrameCount: Int    // how many of `images` are frames from a video, in order
    public var notes: String

    public static let maxImages = 8
    public static let maxImageBytes = 4_500_000 // API limit is 5 MB per image before base64
    public static let maxNotesCharacters = 2_000

    public init(images: [Data], videoFrameCount: Int = 0, notes: String = "") {
        self.images = images
        self.videoFrameCount = videoFrameCount
        self.notes = notes
    }

    /// Boundary validation: rejects requests the API would refuse or that can't produce a result.
    public func validated() throws -> GenerationRequest {
        var copy = self
        copy.notes = String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(GenerationRequest.maxNotesCharacters))
        guard !images.isEmpty || !copy.notes.isEmpty else {
            throw ShadeError(.generationInvalidInput, "Pick an image or video, or describe the look you want.")
        }
        guard images.count <= GenerationRequest.maxImages else {
            throw ShadeError(.generationInvalidInput, "Use at most \(GenerationRequest.maxImages) images.")
        }
        if let big = images.first(where: { $0.count > GenerationRequest.maxImageBytes }) {
            throw ShadeError(.generationInvalidInput, "One of the images is too large (\(big.count / 1_000_000) MB).")
        }
        copy.videoFrameCount = min(max(0, videoFrameCount), images.count)
        return copy
    }

    var instruction: String {
        var text: String
        if images.isEmpty {
            text = "Design a Shade recipe from this description."
        } else if videoFrameCount > 0 {
            text = "These \(images.count) images include \(videoFrameCount) frames sampled in order from a video. "
                + "Recreate the video's visual style (and any motion-driven effects, using `time`) as a Shade recipe for live camera footage."
        } else {
            text = "Recreate the visual style of \(images.count == 1 ? "this image" : "these images") as a Shade recipe for live camera footage."
        }
        if !notes.isEmpty { text += "\n\nWhat I want: \(notes)" }
        return text
    }
}

public struct GenerationResult: Sendable {
    public let recipe: ShaderRecipe
    /// Claude's short description of the style (text before the JSON block).
    public let explanation: String?
    /// How many Claude calls it took (1 = first try compiled).
    public let attempts: Int
}

public enum GenerationProgress: Equatable, Sendable {
    case studying
    case compiling(attempt: Int)
    case fixing(attempt: Int)
}

/// "Show Claude a reference, get a shader that compiles."
///
/// Loop: ask Claude -> parse + validate the recipe -> compile every pass on the device ->
/// if anything fails, send the exact problems back in the same conversation and ask for a full
/// corrected recipe, up to `maxFixAttempts` times.
///
/// Claude's output is untrusted input: it only becomes a recipe after `RecipeCodec` validation and a
/// successful compile. Network retries happen inside the client, not here (one retry layer).
public struct StyleGenerator: Sendable {
    public let client: ClaudeMessaging
    public let compiler: ShaderCompiling
    public let settings: GenerationSettings
    public let maxFixAttempts: Int

    public init(client: ClaudeMessaging, compiler: ShaderCompiling, settings: GenerationSettings, maxFixAttempts: Int = 2) {
        self.client = client
        self.compiler = compiler
        self.settings = settings
        self.maxFixAttempts = maxFixAttempts
    }

    public func generate(_ request: GenerationRequest, progress: @escaping @Sendable (GenerationProgress) -> Void = { _ in }) async throws -> GenerationResult {
        let log = Log.generation
        let request = try request.validated()
        var blocks = request.images.map(ClaudeMessage.jpeg)
        blocks.append(ClaudeMessage.text(request.instruction))
        var messages = [ClaudeMessage.user(blocks)]

        var attempt = 0
        while true {
            try Task.checkCancellation()
            progress(attempt == 0 ? .studying : .fixing(attempt: attempt))
            let response = try await client.send(MessagesRequest(
                model: settings.model.id,
                system: RecipeSpec.systemPrompt,
                messages: messages,
                effort: settings.effort,
                fallbacks: settings.model.supportsServerFallback ? "default" : nil
            ))
            try Task.checkCancellation()
            messages.append(response.asAssistantMessage)

            var problems: [String]
            var candidate: ShaderRecipe?
            do {
                var recipe = try RecipeCodec.extract(from: response.text)
                if recipe.passes.isEmpty { throw ShadeError(.recipeInvalid, "The recipe has no passes.") }
                if recipe.author == nil { recipe.author = "Claude" }
                candidate = recipe
                progress(.compiling(attempt: attempt + 1))
                problems = await compiler.compileProblems(for: recipe)
            } catch let error as ShadeError where error.code == .cancelled {
                throw error
            } catch {
                var message = (error as? ShadeError)?.message ?? String(describing: error)
                if response.stopReason == "max_tokens" { message += " (the reply was cut off before it finished; keep the recipe shorter)" }
                problems = [message]
            }

            if let recipe = candidate, problems.isEmpty {
                log.info("generated recipe after \(attempt + 1) call(s)")
                return GenerationResult(recipe: recipe, explanation: StyleGenerator.prose(from: response.text), attempts: attempt + 1)
            }
            log.warning("attempt \(attempt + 1) unusable: \(problems.count) problem(s)")
            guard attempt < maxFixAttempts else {
                throw ShadeError(.generationFailed,
                                 "Claude's shader still didn't work after \(attempt + 1) tries:\n\n" + problems.joined(separator: "\n\n"))
            }
            attempt += 1
            messages.append(.user([ClaudeMessage.text(
                "The app could not use that recipe. Problems:\n\n\(problems.joined(separator: "\n\n"))\n\n"
                + "Line numbers refer to the pass's `code` (file \"shade\"). Reply with the complete corrected recipe as one ```json block."
            )]))
        }
    }

    /// The text Claude wrote before the JSON block.
    public static func prose(from text: String) -> String? {
        let before = text.components(separatedBy: "```").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return before.isEmpty ? nil : before
    }
}
