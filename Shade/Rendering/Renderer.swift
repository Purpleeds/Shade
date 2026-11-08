import AVFoundation
import CoreVideo
import Metal
import MetalKit
import ShadeCore
import UIKit

/// Draws camera frames (or a still image) through the active recipe's passes.
///
/// Threading: `setRecipe`, `draw(in:)` and the capture APIs run on the main thread. Camera frames
/// arrive on the camera queue and are handed over under `frameLock`. GPU completion handlers hop back
/// to the main thread before touching state.
final class Renderer: NSObject, MTKViewDelegate {
    struct SystemUniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var mixAmount: Float
    }

    struct DisplayUniforms {
        var scale: SIMD2<Float>
        var offset: SIMD2<Float>
    }

    private struct PreparedPass {
        let pipeline: MTLRenderPipelineState
        let floats: [Float]
        let mix: Float
        let isCustom: Bool
    }

    let device: MTLDevice
    let compiler: MetalShaderCompiler
    private let commandQueue: MTLCommandQueue
    private let displayPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let log = Log.render

    private let frameLock = NSLock()
    private var latestFrame: CVMetalTexture?
    private var stillTexture: MTLTexture?
    private(set) var lastFrameSize: CGSize?

    private var recipe: ShaderRecipe?
    private var prepared: [PreparedPass] = []
    private var targets: [MTLTexture] = []
    private let startTime = CACurrentMediaTime()
    private var generation = 0

    private var pendingPhoto: ((Result<UIImage, ShadeError>) -> Void)?
    private var recorder: VideoRecorder?

    /// Main thread. Compile errors for the current recipe (empty when everything compiles).
    var onCompileErrors: (([String]) -> Void)?
    /// Main thread. The GPU reported an error while running the current recipe's passes.
    var onGPUFault: ((ShadeError, _ involvedCustomCode: Bool) -> Void)?
    /// Main thread. The recording stopped because of an error.
    var onRecordingFailed: ((ShadeError) -> Void)?

    private var lastErrors: [String] = []
    private var faultReportedForGeneration = -1

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "display_vertex"),
              let ffn = library.makeFunction(name: "display_fragment") else {
            throw ShadeError(.cameraUnavailable, "This device's GPU couldn't be set up.")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            displayPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw ShadeError(.cameraUnavailable, "This device's GPU couldn't be set up.", detail: String(describing: error))
        }
        self.device = device
        self.commandQueue = queue
        self.compiler = MetalShaderCompiler(device: device)
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    // MARK: Input

    /// Wires the camera to this renderer. The closure runs on the camera queue.
    func attach(to camera: CameraService) {
        camera.onFrame = { [weak self] buffer in self?.enqueue(buffer) }
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTexture else { return }
        frameLock.lock()
        latestFrame = cvTexture
        frameLock.unlock()
    }

    /// Use a still image instead of the camera (nil returns to the camera).
    func setStillImage(_ image: UIImage?) throws {
        guard let image else {
            stillTexture = nil
            return
        }
        guard let cg = ImageUtils.normalizedCGImage(image, maxDimension: 2048) else {
            throw ShadeError(.generationInvalidInput, "That photo couldn't be read.")
        }
        do {
            stillTexture = try MTKTextureLoader(device: device).newTexture(cgImage: cg, options: [
                .SRGB: false,
                .origin: MTKTextureLoader.Origin.topLeft.rawValue,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ])
        } catch {
            throw ShadeError(.generationInvalidInput, "That photo couldn't be loaded.", detail: String(describing: error))
        }
    }

    // MARK: Recipe

    func setRecipe(_ recipe: ShaderRecipe) {
        self.recipe = recipe
        generation += 1
        rebuild()
    }

    private func rebuild() {
        guard let recipe else { return }
        var passes: [PreparedPass] = []
        var errors: [String] = []
        for (i, pass) in recipe.passes.enumerated() where pass.enabled {
            if let problem = RecipeValidator.problem(in: pass) {
                errors.append("Pass \(i + 1) (\(pass.displayName)): \(problem)")
                continue
            }
            guard let source = ShaderSource.source(for: pass) else { continue }
            switch compiler.cached(source) {
            case .success(let pipeline):
                passes.append(PreparedPass(pipeline: pipeline, floats: ShaderSource.floats(for: pass), mix: pass.mix, isCustom: pass.isCustom))
            case .failure(let error):
                errors.append("Pass \(i + 1) (\(pass.displayName)):\n\(error.message)")
            case nil:
                compiler.compile(source) { [weak self] _ in
                    DispatchQueue.main.async { self?.rebuild() }
                }
            }
        }
        prepared = passes
        if errors != lastErrors {
            lastErrors = errors
            onCompileErrors?(errors)
        }
    }

    // MARK: Capture

    /// Captures the next processed frame. Fails after 2 seconds if no frame arrives (camera not ready).
    func capturePhoto(_ completion: @escaping (Result<UIImage, ShadeError>) -> Void) {
        if pendingPhoto != nil {
            completion(.failure(ShadeError(.captureFailed, "Still saving the previous photo.")))
            return
        }
        pendingPhoto = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let pending = self.pendingPhoto else { return }
            self.pendingPhoto = nil
            pending(.failure(ShadeError(.captureFailed, "The camera isn't ready yet. Try again in a moment.")))
        }
    }

    var isRecording: Bool { recorder != nil }

    func startRecording() throws {
        guard recorder == nil else { return }
        guard let size = lastFrameSize else {
            throw ShadeError(.captureFailed, "The camera isn't ready yet. Try again in a moment.")
        }
        if let free = TemporaryFiles.availableCapacity(), free < VideoRecorder.minimumFreeBytes {
            throw ShadeError(.insufficientStorage, "Not enough free storage to record video.", detail: "\(free) bytes free")
        }
        recorder = try VideoRecorder(device: device, width: Int(size.width), height: Int(size.height))
    }

    func stopRecording() async throws -> URL {
        guard let rec = recorder else {
            throw ShadeError(.captureFailed, "Nothing is being recorded.")
        }
        recorder = nil
        return try await rec.finish()
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func ensureTargets(width: Int, height: Int) {
        if let t = targets.first, t.width == width, t.height == height { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalShaderCompiler.intermediateFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        targets = (0..<2).compactMap { _ in device.makeTexture(descriptor: desc) }
        if targets.count != 2 { log.error("could not allocate \(width)x\(height) render targets") }
    }

    func draw(in view: MTKView) {
        var frameRef: CVMetalTexture?
        let source: MTLTexture?
        if let still = stillTexture {
            source = still
        } else {
            frameLock.lock()
            frameRef = latestFrame
            frameLock.unlock()
            source = frameRef.flatMap { CVMetalTextureGetTexture($0) }
        }
        guard let input = source,
              let drawable = view.currentDrawable,
              let screenPass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        lastFrameSize = CGSize(width: input.width, height: input.height)
        ensureTargets(width: input.width, height: input.height)
        var current = input
        var system = SystemUniforms(resolution: SIMD2(Float(input.width), Float(input.height)),
                                    time: Float(CACurrentMediaTime() - startTime), mixAmount: 1)
        var ranCustomCode = false

        if targets.count == 2 {
            for (i, pass) in prepared.enumerated() {
                let target = targets[i % 2]
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = target
                rpd.colorAttachments[0].loadAction = .dontCare
                rpd.colorAttachments[0].storeAction = .store
                guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { break }
                enc.setRenderPipelineState(pass.pipeline)
                enc.setFragmentTexture(current, index: 0)
                enc.setFragmentTexture(input, index: 1)
                system.mixAmount = pass.mix
                enc.setFragmentBytes(&system, length: MemoryLayout<SystemUniforms>.stride, index: 0)
                pass.floats.withUnsafeBytes { bytes in
                    enc.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                }
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
                current = target
                ranCustomCode = ranCustomCode || pass.isCustom
            }
        }

        drawProcessed(current, into: screenPass, commandBuffer: commandBuffer,
                      uniforms: Renderer.aspectFill(texture: CGSize(width: input.width, height: input.height), target: view.drawableSize))

        if let completion = pendingPhoto {
            pendingPhoto = nil
            capture(current, commandBuffer: commandBuffer, completion: completion)
        }

        if let rec = recorder {
            rec.encodeFrame(from: current, commandBuffer: commandBuffer, pipeline: displayPipeline)
            if let failure = rec.failure {
                recorder = nil
                rec.cancel()
                onRecordingFailed?(failure)
            } else if rec.duration >= VideoRecorder.maximumDuration {
                log.notice("recording reached the maximum length")
                recorder = nil
                Task { @MainActor [weak self] in
                    do {
                        let url = try await rec.finish()
                        self?.onRecordingReachedLimit?(url)
                    } catch {
                        self?.onRecordingFailed?(ShadeError.wrap(error, as: .captureFailed, "The recording couldn't be saved."))
                    }
                }
            }
        }

        let keepAlive = frameRef
        let renderGeneration = generation
        let custom = ranCustomCode
        commandBuffer.addCompletedHandler { [weak self] buffer in
            _ = keepAlive // keep the camera buffer alive until the GPU is done with it
            guard buffer.status == .error else { return }
            let detail = String(describing: buffer.error)
            DispatchQueue.main.async { self?.handleGPUFault(detail: detail, generation: renderGeneration, involvedCustomCode: custom) }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Main thread. The recording hit `maximumDuration` and was finished automatically.
    var onRecordingReachedLimit: ((URL) -> Void)?

    /// Reports a GPU fault once per recipe version, so a looping shader doesn't produce an alert per frame.
    private func handleGPUFault(detail: String, generation faultGeneration: Int, involvedCustomCode: Bool) {
        log.error("GPU command buffer failed (custom code: \(involvedCustomCode)): \(detail)")
        guard faultGeneration == generation, faultReportedForGeneration != generation else { return }
        faultReportedForGeneration = generation
        let message = involvedCustomCode
            ? "A custom shader pass crashed the GPU (it probably runs too long per pixel), so custom passes were turned off."
            : "The GPU reported an error while drawing."
        onGPUFault?(ShadeError(.gpuFault, message, detail: detail), involvedCustomCode)
    }

    private func drawProcessed(_ texture: MTLTexture, into pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, uniforms: DisplayUniforms) {
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        enc.setRenderPipelineState(displayPipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    static let identityUniforms = DisplayUniforms(scale: SIMD2(1, 1), offset: SIMD2(0, 0))

    static func aspectFill(texture: CGSize, target: CGSize) -> DisplayUniforms {
        guard texture.width > 0, texture.height > 0, target.width > 0, target.height > 0 else { return identityUniforms }
        let ta = Float(texture.width / texture.height)
        let va = Float(target.width / target.height)
        if ta > va {
            let sx = va / ta
            return DisplayUniforms(scale: SIMD2(sx, 1), offset: SIMD2((1 - sx) / 2, 0))
        } else {
            let sy = ta / va
            return DisplayUniforms(scale: SIMD2(1, sy), offset: SIMD2(0, (1 - sy) / 2))
        }
    }

    private func capture(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer, completion: @escaping (Result<UIImage, ShadeError>) -> Void) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: texture.width, height: texture.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let output = device.makeTexture(descriptor: desc) else {
            completion(.failure(ShadeError(.captureFailed, "Not enough memory to capture a photo.")))
            return
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = output
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        drawProcessed(texture, into: rpd, commandBuffer: commandBuffer, uniforms: Renderer.identityUniforms)
        commandBuffer.addCompletedHandler { buffer in
            let result: Result<UIImage, ShadeError>
            if buffer.status == .error {
                result = .failure(ShadeError(.captureFailed, "The photo couldn't be captured.", detail: String(describing: buffer.error)))
            } else if let image = ImageUtils.image(fromBGRA: output) {
                result = .success(image)
            } else {
                result = .failure(ShadeError(.captureFailed, "The photo couldn't be captured."))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
