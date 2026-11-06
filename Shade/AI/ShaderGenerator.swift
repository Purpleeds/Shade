import Metal
import SwiftUI

/// Runs the "show Claude a reference, get a working shader" loop:
/// send images -> parse recipe -> compile on device -> on errors, send them back for a fix (up to 2 times).
@MainActor
final class ShaderGenerator: ObservableObject {
    @Published var isRunning = false
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var result: ShaderRecipe?
    @Published var explanation: String?

    private var task: Task<Void, Never>?
    static let maxFixAttempts = 2

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        status = ""
    }

    func generate(media: ReferenceMedia, notes: String, client: ClaudeClient, device: MTLDevice) {
        cancel()
        errorMessage = nil
        result = nil
        explanation = nil
        isRunning = true
        task = Task { [weak self] in
            do {
                let recipe = try await self?.run(media: media, notes: notes, client: client, device: device)
                guard let self, !Task.isCancelled else { return }
                self.result = recipe
                self.status = "Done"
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.status = ""
            }
            self?.isRunning = false
        }
    }

    private func run(media: ReferenceMedia, notes: String, client: ClaudeClient, device: MTLDevice) async throws -> ShaderRecipe {
        var content: [[String: Any]] = []
        for image in media.images {
            if let jpeg = ImageUtils.jpegForClaude(image) { content.append(ClaudeClient.imageBlock(jpeg: jpeg)) }
        }
        var instruction: String
        if media.isEmpty {
            instruction = "Design a Shade recipe from this description."
        } else if media.videoFrameCount > 0 {
            instruction = "These \(media.images.count) images include \(media.videoFrameCount) frames sampled in order from a video. " +
                "Recreate the video's visual style (and any motion-driven effects, using `time`) as a Shade recipe for live camera footage."
        } else {
            instruction = "Recreate the visual style of \(media.images.count == 1 ? "this image" : "these images") as a Shade recipe for live camera footage."
        }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty { instruction += "\n\nWhat I want: \(trimmedNotes)" }
        content.append(ClaudeClient.textBlock(instruction))

        var messages: [[String: Any]] = [["role": "user", "content": content]]
        var attempt = 0
        while true {
            try Task.checkCancellation()
            status = attempt == 0 ? "Claude is studying the style…" : "Claude is fixing the shader (attempt \(attempt))…"
            let reply = try await client.send(system: RecipeSpec.systemPrompt, messages: messages)
            try Task.checkCancellation()
            messages.append(["role": "assistant", "content": reply.content])

            var problems: [String]
            var recipe: ShaderRecipe?
            do {
                recipe = try ShaderRecipe.extract(from: reply.text)
                status = "Compiling on your GPU…"
                let candidate = recipe!
                problems = await Task.detached(priority: .userInitiated) {
                    ShaderCompiler.validate(candidate, device: device)
                }.value
                if candidate.passes.isEmpty { problems.append("The recipe has no passes.") }
            } catch {
                problems = [error.localizedDescription + (reply.stopReason == "max_tokens" ? " (the reply was cut off; make it shorter)" : "")]
            }

            if var recipe, problems.isEmpty {
                if recipe.author == nil { recipe.author = "Claude" }
                explanation = ShaderGenerator.prose(from: reply.text)
                return recipe
            }
            guard attempt < ShaderGenerator.maxFixAttempts else {
                throw GenerationError.stillBroken(problems.joined(separator: "\n\n"))
            }
            attempt += 1
            messages.append(["role": "user", "content": [ClaudeClient.textBlock(
                "The app could not use that recipe. Problems:\n\n\(problems.joined(separator: "\n\n"))\n\n" +
                "Line numbers refer to the pass's `code` (file \"shade\"). Reply with the complete corrected recipe as one ```json block."
            )]])
        }
    }

    /// The text Claude wrote before the JSON block.
    static func prose(from text: String) -> String? {
        let before = text.components(separatedBy: "```").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return before.isEmpty ? nil : before
    }

    enum GenerationError: LocalizedError {
        case stillBroken(String)
        var errorDescription: String? {
            switch self {
            case .stillBroken(let details): return "Claude's shader still didn't compile after several fixes:\n\n\(details)"
            }
        }
    }
}
