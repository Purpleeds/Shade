import Foundation
import Metal
import ShadeCore

/// Compiles pass sources into render pipelines at runtime and caches them.
///
/// One instance is shared by the renderer and by AI generation, so a shader Claude wrote is compiled
/// once while validating and is ready instantly when applied.
///
/// Thread-safe: the cache is guarded by a lock; compiles run on a background queue and identical
/// concurrent requests share one compile.
final class MetalShaderCompiler: ShaderCompiling, @unchecked Sendable {
    typealias Outcome = Result<MTLRenderPipelineState, ShadeError>

    static let intermediateFormat: MTLPixelFormat = .rgba16Float
    static let cacheLimit = 48

    let device: MTLDevice
    private let lock = NSLock()
    private var cache: [String: (outcome: Outcome, lastUse: UInt64)] = [:]
    private var waiters: [String: [(Outcome) -> Void]] = [:]
    private var useCounter: UInt64 = 0
    private let queue = DispatchQueue(label: "shade.shader-compiler", qos: .userInitiated, attributes: .concurrent)
    private let log = Log.shaders

    init(device: MTLDevice) {
        self.device = device
    }

    /// Non-blocking lookup for the render loop.
    func cached(_ source: String) -> Outcome? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = cache[source] else { return nil }
        useCounter += 1
        entry.lastUse = useCounter
        cache[source] = entry
        return entry.outcome
    }

    /// Compiles (or returns the cached result). `completion` runs on an arbitrary queue.
    func compile(_ source: String, completion: @escaping (Outcome) -> Void) {
        lock.lock()
        if let entry = cache[source] {
            lock.unlock()
            completion(entry.outcome)
            return
        }
        if waiters[source] != nil {
            waiters[source]!.append(completion)
            lock.unlock()
            return
        }
        waiters[source] = [completion]
        lock.unlock()

        let device = self.device
        queue.async { [weak self] in
            let started = Date()
            let outcome = MetalShaderCompiler.build(source: source, device: device)
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if case .failure(let error) = outcome {
                self.log.notice("compile failed in \(ms)ms: \(error.detail ?? error.message)")
            } else {
                self.log.info("compiled pipeline in \(ms)ms")
            }
            self.lock.lock()
            self.store(source, outcome)
            let callbacks = self.waiters.removeValue(forKey: source) ?? []
            self.lock.unlock()
            callbacks.forEach { $0(outcome) }
        }
    }

    func compile(_ source: String) async -> Outcome {
        await withCheckedContinuation { continuation in
            compile(source) { continuation.resume(returning: $0) }
        }
    }

    // MARK: ShaderCompiling

    func compileProblems(for recipe: ShaderRecipe) async -> [String] {
        var problems = RecipeValidator.problems(in: recipe)
        guard problems.isEmpty else { return problems }
        for (i, pass) in recipe.passes.enumerated() {
            guard let source = ShaderSource.source(for: pass) else { continue }
            if case .failure(let error) = await compile(source) {
                problems.append("Pass \(i + 1) (\(pass.displayName)) failed to compile:\n\(error.message)")
            }
        }
        return problems
    }

    // MARK: Internals

    /// Must be called with `lock` held.
    private func store(_ source: String, _ outcome: Outcome) {
        if cache.count >= MetalShaderCompiler.cacheLimit,
           let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            cache.removeValue(forKey: oldest)
        }
        useCounter += 1
        cache[source] = (outcome, useCounter)
    }

    private static func build(source: String, device: MTLDevice) -> Outcome {
        do {
            let library = try device.makeLibrary(source: source, options: MTLCompileOptions())
            guard let vertex = library.makeFunction(name: ShaderSource.vertexFunctionName),
                  let fragment = library.makeFunction(name: ShaderSource.fragmentFunctionName) else {
                return .failure(ShadeError(.shaderCompileFailed, "The shader is missing its entry points."))
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = intermediateFormat
            return .success(try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            let raw = error.localizedDescription
            return .failure(ShadeError(.shaderCompileFailed, readableCompilerOutput(raw), detail: String(raw.prefix(2000))))
        }
    }

    /// Keeps the useful part of Metal compiler output: error lines plus the code line and caret after each.
    static func readableCompilerOutput(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var kept: [String] = []
        for (i, line) in lines.enumerated() where line.contains("error:") {
            kept.append(line.replacingOccurrences(of: "program_source:", with: ""))
            if i + 1 < lines.count, !lines[i + 1].contains(": ") { kept.append(lines[i + 1]) }
            if i + 2 < lines.count, lines[i + 2].contains("^") { kept.append(lines[i + 2]) }
        }
        var text = kept.isEmpty ? raw : kept.joined(separator: "\n")
        if text.count > 3000 { text = String(text.prefix(3000)) + "\n…" }
        return text
    }
}
