import AVFoundation
import CoreVideo
import Metal
import MetalKit
import UIKit

/// Draws camera frames (or a still image) through the current recipe's passes.
/// `setRecipe`, `draw(in:)` and the capture APIs are called on the main thread; camera frames arrive on the camera queue.
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
    }

    let device: MTLDevice
    let compiler: ShaderCompiler
    private let commandQueue: MTLCommandQueue
    private let displayPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    private let frameLock = NSLock()
    private var latestFrame: CVMetalTexture?
    private var stillTexture: MTLTexture?

    private var recipe: ShaderRecipe?
    private var prepared: [PreparedPass] = []
    private var targets: [MTLTexture] = []
    private let startTime = CACurrentMediaTime()

    private var pendingPhoto: ((UIImage?) -> Void)?
    private(set) var recorder: VideoRecorder?

    /// Called on the main thread whenever the set of compile errors changes.
    var onCompileErrors: (([String]) -> Void)?
    private var lastErrors: [String] = []

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device,
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "display_vertex"),
              let ffn = library.makeFunction(name: "display_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.device = device
        self.commandQueue = queue
        self.displayPipeline = pipeline
        self.compiler = ShaderCompiler(device: device)
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    // MARK: Input

    /// Wires the camera to this renderer. Called once; the closure runs on the camera queue.
    func attach(to camera: CameraManager) {
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
    func setStillImage(_ image: UIImage?) {
        guard let image, let cg = ImageUtils.normalizedCGImage(image, maxDimension: 2048) else {
            stillTexture = nil
            return
        }
        let loader = MTKTextureLoader(device: device)
        stillTexture = try? loader.newTexture(cgImage: cg, options: [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft.rawValue,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ])
    }

    // MARK: Recipe

    func setRecipe(_ recipe: ShaderRecipe) {
        self.recipe = recipe
        rebuild()
    }

    private func rebuild() {
        guard let recipe else { return }
        var passes: [PreparedPass] = []
        var errors: [String] = []
        for (i, pass) in recipe.passes.enumerated() where pass.enabled {
            if let problem = pass.structuralProblem {
                errors.append("Pass \(i + 1) (\(pass.displayName)): \(problem)")
                continue
            }
            guard let source = ShaderSource.source(for: pass) else { continue }
            switch compiler.cached(source) {
            case .success(let pipeline):
                passes.append(PreparedPass(pipeline: pipeline, floats: ShaderSource.floats(for: pass), mix: pass.mix))
            case .failure(let err):
                errors.append("Pass \(i + 1) (\(pass.displayName)):\n\(err.message)")
            case nil:
                compiler.compileIfNeeded(source) { [weak self] in self?.rebuild() }
            }
        }
        prepared = passes
        if errors != lastErrors {
            lastErrors = errors
            onCompileErrors?(errors)
        }
    }

    // MARK: Capture

    func capturePhoto(_ completion: @escaping (UIImage?) -> Void) {
        pendingPhoto = completion
    }

    func startRecording() throws {
        guard recorder == nil else { return }
        recorder = try VideoRecorder(device: device)
    }

    func stopRecording(_ completion: @escaping (URL?) -> Void) {
        guard let rec = recorder else { completion(nil); return }
        recorder = nil
        rec.finish(completion)
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func ensureTargets(width: Int, height: Int) {
        if let t = targets.first, t.width == width, t.height == height { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderCompiler.intermediateFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        targets = (0..<2).compactMap { _ in device.makeTexture(descriptor: desc) }
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

        ensureTargets(width: input.width, height: input.height)
        var current = input
        var system = SystemUniforms(resolution: SIMD2(Float(input.width), Float(input.height)),
                                    time: Float(CACurrentMediaTime() - startTime), mixAmount: 1)

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
            }
        }

        // Screen (aspect fill).
        let drawableSize = view.drawableSize
        drawProcessed(current, into: screenPass, commandBuffer: commandBuffer,
                      uniforms: Renderer.aspectFill(texture: CGSize(width: input.width, height: input.height), target: drawableSize))

        // Photo capture.
        if let completion = pendingPhoto {
            pendingPhoto = nil
            capture(current, commandBuffer: commandBuffer, completion: completion)
        }

        // Video recording.
        if let rec = recorder {
            rec.encodeFrame(from: current, commandBuffer: commandBuffer, pipeline: displayPipeline)
        }

        let keepAlive = frameRef
        commandBuffer.addCompletedHandler { _ in
            _ = keepAlive // keep the camera buffer alive until the GPU is done with it
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
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

    private func capture(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer, completion: @escaping (UIImage?) -> Void) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: texture.width, height: texture.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let output = device.makeTexture(descriptor: desc) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = output
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        drawProcessed(texture, into: rpd, commandBuffer: commandBuffer, uniforms: Renderer.identityUniforms)
        commandBuffer.addCompletedHandler { _ in
            let image = ImageUtils.image(fromBGRA: output)
            DispatchQueue.main.async { completion(image) }
        }
    }
}
