import Foundation
import ShadeCore

/// UI state for "Create with Claude". The pipeline itself (prompting, parsing, the compile-fix loop,
/// retries) lives in ShadeCore's `StyleGenerator`; this only drives it and publishes progress.
@MainActor
final class GenerationController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var error: ShadeError?
    @Published private(set) var result: GenerationResult?

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        status = ""
    }

    func generate(media: ReferenceMedia, notes: String, settings: GenerationSettings, compiler: ShaderCompiling) {
        cancel()
        error = nil
        result = nil
        let request: GenerationRequest
        let client: ClaudeClient
        do {
            guard let key = try KeychainSecretStore.claudeAPIKey.read() else {
                throw ShadeError(.claudeMissingKey, "Add your Claude API key in Settings first (create one at console.anthropic.com).")
            }
            client = try ClaudeClient(apiKey: key)
            request = try media.generationRequest(notes: notes).validated()
        } catch {
            self.error = ShadeError.wrap(error, as: .generationFailed, "Couldn't start generating.")
            return
        }

        isRunning = true
        status = "Preparing…"
        let generator = StyleGenerator(client: client, compiler: compiler, settings: settings)
        task = Task { [weak self] in
            do {
                let result = try await generator.generate(request) { [weak self] progress in
                    Task { @MainActor [weak self] in self?.status = GenerationController.describe(progress) }
                }
                guard !Task.isCancelled else { return }
                self?.result = result
                self?.status = "Done"
            } catch {
                guard !Task.isCancelled else { return }
                let shade = ShadeError.wrap(error, as: .generationFailed, "Generation failed.")
                if shade.code != .cancelled { self?.error = shade }
                self?.status = ""
            }
            self?.isRunning = false
        }
    }

    static func describe(_ progress: GenerationProgress) -> String {
        switch progress {
        case .studying: return "Claude is studying the style…"
        case .compiling(let attempt): return attempt == 1 ? "Compiling on your GPU…" : "Compiling the fix…"
        case .fixing(let attempt): return "Claude is fixing the shader (attempt \(attempt))…"
        }
    }
}
