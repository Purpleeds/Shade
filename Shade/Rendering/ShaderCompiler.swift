import Foundation
import Metal

struct ShaderCompileError: Error, LocalizedError, Hashable {
    let message: String
    var errorDescription: String? { message }
}

/// Compiles pass sources into render pipelines at runtime and caches them by source text.
/// The cache is only touched on the main thread; compilation itself runs in the background.
final class ShaderCompiler {
    static let intermediateFormat: MTLPixelFormat = .rgba16Float

    let device: MTLDevice
    private var cache: [String: Result<MTLRenderPipelineState, ShaderCompileError>] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "shade.shader-compiler", qos: .userInitiated, attributes: .concurrent)

    init(device: MTLDevice) {
        self.device = device
    }

    func cached(_ source: String) -> Result<MTLRenderPipelineState, ShaderCompileError>? {
        cache[source]
    }

    /// Starts compiling `source` if it isn't cached or already compiling. `completion` runs on the main thread.
    func compileIfNeeded(_ source: String, completion: @escaping () -> Void) {
        guard cache[source] == nil, !inFlight.contains(source) else { return }
        inFlight.insert(source)
        let device = self.device
        queue.async { [weak self] in
            let result = ShaderCompiler.compile(source: source, device: device)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(source)
                if self.cache.count > 64 { self.cache.removeAll() }
                self.cache[source] = result
                completion()
            }
        }
    }

    /// Synchronous compile, safe on any thread. Used to validate recipes Claude writes before showing them.
    static func compile(source: String, device: MTLDevice) -> Result<MTLRenderPipelineState, ShaderCompileError> {
        let options = MTLCompileOptions() // fast math is on by default
        do {
            let library = try device.makeLibrary(source: source, options: options)
            guard let vertex = library.makeFunction(name: ShaderSource.vertexFunctionName),
                  let fragment = library.makeFunction(name: ShaderSource.fragmentFunctionName) else {
                return .failure(ShaderCompileError(message: "The shader is missing its entry points."))
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = intermediateFormat
            return .success(try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            return .failure(ShaderCompileError(message: cleanup(error.localizedDescription)))
        }
    }

    /// Compiles every pass of a recipe and returns readable problems (empty = all good). Safe on any thread.
    static func validate(_ recipe: ShaderRecipe, device: MTLDevice) -> [String] {
        var problems = recipe.structuralProblems
        if !problems.isEmpty { return problems }
        for (i, pass) in recipe.passes.enumerated() {
            guard let source = ShaderSource.source(for: pass) else { continue }
            if case .failure(let err) = compile(source: source, device: device) {
                problems.append("Pass \(i + 1) (\(pass.displayName)) failed to compile:\n\(err.message)")
            }
        }
        return problems
    }

    /// Keeps the useful part of Metal compiler output: error lines (and the code line + caret that follow).
    static func cleanup(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var kept: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.contains("error:") {
                kept.append(line.replacingOccurrences(of: "program_source:", with: ""))
                if i + 1 < lines.count, !lines[i + 1].contains(": ") { kept.append(lines[i + 1]) }
                if i + 2 < lines.count, lines[i + 2].contains("^") { kept.append(lines[i + 2]) }
            }
            i += 1
        }
        var text = kept.isEmpty ? raw : kept.joined(separator: "\n")
        if text.count > 3000 { text = String(text.prefix(3000)) + "\n…" }
        return text
    }
}
