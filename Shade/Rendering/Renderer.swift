import AVFoundation
import CoreVideo
import Metal
import MetalKit
import QuartzCore
import ShadeCore
import UIKit

/// Frame-rate and resolution figures for the optional on-screen readout.
struct RenderStats: Equatable {
    var fps: Double
    var gpuMilliseconds: Double
    var processingSize: PixelSize
    /// 1 = the chosen resolution; lower while Smooth mode is easing a heavy look.
    var scale: Double
    var droppedFrames: Int
}

/// Draws camera frames (or a still image) through the active look's passes.
///
/// Threading, built so the UI never waits for the GPU:
/// - **Main thread:** configuration (`setRecipe`, settings, capture requests) and all callbacks.
/// - **Render queue:** owns every texture and per-frame state; encodes, presents and commits frames.
/// - **Camera queue:** hands each new frame over (under `stateLock`) and schedules one render.
///
/// Each camera frame is rendered once. At most two frames are on the GPU at a time; if the GPU is
/// behind, the newest frame is dropped rather than queued, so latency never builds up.
final class Renderer {
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
        /// Set for feedback passes: the key of the texture holding this pass's previous output.
        let historyKey: UUID?
    }

    private struct PreparedLook {
        var passes: [PreparedPass] = []
        var generation = 0
    }

    // MARK: Immutable

    let device: MTLDevice
    let compiler: MetalShaderCompiler
    private let commandQueue: MTLCommandQueue
    private let displayPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let renderQueue = DispatchQueue(label: "shade.render", qos: .userInteractive)
    private let inFlight = DispatchSemaphore(value: 2)
    private let startTime = CACurrentMediaTime()
    private let log = Log.render

    // MARK: Shared (guarded by stateLock)

    private let stateLock = NSLock()
    private var latestFrame: CVMetalTexture?
    private var renderScheduled = false
    private weak var metalLayer: CAMetalLayer?
    private var drawableSize: CGSize = .zero
    private var stillActive = false
    private var sharedDisplayUniforms = Renderer.identityUniforms
    private var sharedFullSize: PixelSize?

    // MARK: Render queue only

    private var prepared = PreparedLook()
    private var stillTexture: MTLTexture?
    private var targets: [MTLTexture] = []
    private var history: [UUID: MTLTexture] = [:]
    private var primedHistory: Set<UUID> = []
    private var bypass = false
    private var resolution = ProcessingResolution.defaultValue
    private var smoothMode = true
    private var governor = FrameRateGovernor(targetFPS: 30)
    private var pendingPhoto: (token: UUID, completion: (Result<UIImage, ShadeError>) -> Void)?
    private var recorder: VideoRecorder?
    private var statFrames = 0
    private var statGPUTime = 0.0
    private var statDropped = 0
    private var statWindowStart = CACurrentMediaTime()
    private var lastLiveSize = PixelSize(width: 0, height: 0)

    // MARK: Main thread only

    private var recipe: ShaderRecipe?
    private var generation = 0
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var pipelineFailures: [String: ShadeError] = [:]
    private var lastErrors: [String] = []
    private var faultReportedForGeneration = -1

    /// Main thread. Compile errors for the current recipe (empty when everything compiles).
    var onCompileErrors: (([String]) -> Void)?
    /// Main thread. The GPU reported an error while running the current recipe's passes.
    var onGPUFault: ((ShadeError, _ involvedCustomCode: Bool) -> Void)?
    /// Main thread. The recording stopped because of an error.
    var onRecordingFailed: ((ShadeError) -> Void)?
    /// Main thread. The recording hit `maximumDuration` and was finished automatically.
    var onRecordingReachedLimit: ((URL) -> Void)?
    /// Main thread, about twice a second. Leave nil when nobody shows the numbers.
    var onStats: ((RenderStats) -> Void)?

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
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    // MARK: Surface

    /// Called by the preview view once its layer exists.
    func attach(layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        stateLock.lock()
        metalLayer = layer
        stateLock.unlock()
    }

    func setDrawableSize(_ size: CGSize) {
        stateLock.lock()
        drawableSize = size
        stateLock.unlock()
        scheduleRender()
    }

    /// Display-link tick (main thread, ~30 Hz). Only drives rendering for still images; the camera drives itself.
    func displayTick() {
        stateLock.lock()
        let still = stillActive
        stateLock.unlock()
        if still { scheduleRender() }
    }

    // MARK: Input

    /// Wires the camera to this renderer. The closure runs on the camera queue.
    func attach(to camera: CameraService) {
        camera.onFrame = { [weak self] buffer in self?.enqueue(buffer) }
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache else { return }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard let cvTexture else { return }
        stateLock.lock()
        latestFrame = cvTexture
        stateLock.unlock()
        scheduleRender()
    }

    /// Use a still image instead of the camera (nil returns to the camera).
    func setStillImage(_ image: UIImage?) throws {
        guard let image else {
            setStill(nil)
            return
        }
        guard let cg = ImageUtils.normalizedCGImage(image, maxDimension: CGFloat(ProcessingResolution.p2160.longSide)) else {
            throw ShadeError(.generationInvalidInput, "That photo couldn't be read.")
        }
        do {
            let texture = try MTKTextureLoader(device: device).newTexture(cgImage: cg, options: [
                .SRGB: false,
                .origin: MTKTextureLoader.Origin.topLeft.rawValue,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ])
            setStill(texture)
        } catch {
            throw ShadeError(.generationInvalidInput, "That photo couldn't be loaded.", detail: String(describing: error))
        }
    }

    private func setStill(_ texture: MTLTexture?) {
        stateLock.lock()
        stillActive = texture != nil
        stateLock.unlock()
        renderQueue.async { self.stillTexture = texture }
        scheduleRender()
    }

    // MARK: Settings (main thread)

    func setResolution(_ value: ProcessingResolution) {
        renderQueue.async {
            self.resolution = value
            self.governor.reset()
        }
        scheduleRender()
    }

    func setSmoothMode(_ enabled: Bool) {
        renderQueue.async {
            self.smoothMode = enabled
            self.governor.reset()
        }
    }

    /// Hold-to-compare: shows the untouched camera while true.
    func setBypass(_ enabled: Bool) {
        renderQueue.async { self.bypass = enabled }
        scheduleRender()
    }

    // MARK: Recipe (main thread)

    func setRecipe(_ recipe: ShaderRecipe) {
        self.recipe = recipe
        generation += 1
        rebuild()
    }

    private func rebuild() {
        guard let recipe else { return }
        var passes: [PreparedPass] = []
        var errors: [String] = []
        // Passes mixed to 0 change nothing, so they cost nothing.
        for (i, pass) in recipe.passes.enumerated() where pass.enabled && pass.mix > 0.001 {
            if let problem = RecipeValidator.problem(in: pass) {
                errors.append("Pass \(i + 1) (\(pass.displayName)): \(problem)")
                continue
            }
            switch prepare(pass) {
            case .success(let prepared?): passes.append(prepared)
            case .success(nil): break
            case .failure(let error): errors.append("Pass \(i + 1) (\(pass.displayName)):\n\(error.message)")
            }
        }
        // Look-wide intensity: blend the finished look back toward the untouched camera image.
        if recipe.intensity < 0.999, !passes.isEmpty {
            var blend = ShaderPass.builtIn("blendOriginal", ["amount": [1 - recipe.intensity], "mode": [0]])
            blend.id = Renderer.intensityPassID
            if case .success(let prepared?) = prepare(blend) { passes.append(prepared) }
        }
        let look = PreparedLook(passes: passes, generation: generation)
        renderQueue.async {
            self.prepared = look
            let liveKeys = Set(passes.compactMap(\.historyKey))
            self.history = self.history.filter { liveKeys.contains($0.key) }
            self.primedHistory.formIntersection(liveKeys)
        }
        scheduleRender()
        if errors != lastErrors {
            lastErrors = errors
            onCompileErrors?(errors)
        }
    }

    private static let intensityPassID = UUID()

    /// A ready pipeline, nil while it compiles (a rebuild follows), or the compile error.
    /// Pipelines are looked up by structure key, so slider moves never rebuild shader source.
    private func prepare(_ pass: ShaderPass) -> Result<PreparedPass?, ShadeError> {
        guard let key = ShaderSource.structureKey(for: pass) else { return .success(nil) }
        func ready(_ pipeline: MTLRenderPipelineState) -> PreparedPass {
            PreparedPass(pipeline: pipeline, floats: ShaderSource.floats(for: pass), mix: pass.mix,
                         isCustom: pass.isCustom, historyKey: pass.usesHistory ? pass.id : nil)
        }
        if let pipeline = pipelines[key] { return .success(ready(pipeline)) }
        if let failure = pipelineFailures[key] { return .failure(failure) }
        guard let source = ShaderSource.source(for: pass) else { return .success(nil) }
        switch compiler.cached(source) {
        case .success(let pipeline):
            if pipelines.count > 64 { pipelines.removeAll() }
            pipelines[key] = pipeline
            return .success(ready(pipeline))
        case .failure(let error):
            if pipelineFailures.count > 64 { pipelineFailures.removeAll() }
            pipelineFailures[key] = error
            return .failure(error)
        case nil:
            compiler.compile(source) { [weak self] _ in
                DispatchQueue.main.async { self?.rebuild() }
            }
            return .success(nil)
        }
    }

    /// Converts a point in the preview (view coordinates) into image coordinates (0...1, top-left origin).
    func imageCoordinate(forViewPoint point: CGPoint, viewSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        stateLock.lock()
        let u = sharedDisplayUniforms
        stateLock.unlock()
        let x = Float(point.x / viewSize.width) * u.scale.x + u.offset.x
        let y = Float(point.y / viewSize.height) * u.scale.y + u.offset.y
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    // MARK: Capture (main thread API)

    /// Captures the next frame at the full chosen resolution, even while Smooth mode has lowered the preview.
    /// `completion` runs on the main thread. Fails after 2 seconds if no frame arrives (camera not ready).
    func capturePhoto(_ completion: @escaping (Result<UIImage, ShadeError>) -> Void) {
        let deliver: (Result<UIImage, ShadeError>) -> Void = { result in DispatchQueue.main.async { completion(result) } }
        let token = UUID()
        renderQueue.async {
            guard self.pendingPhoto == nil else {
                deliver(.failure(ShadeError(.captureFailed, "Still saving the previous photo.")))
                return
            }
            self.pendingPhoto = (token, deliver)
            self.renderQueue.asyncAfter(deadline: .now() + 2) {
                guard let pending = self.pendingPhoto, pending.token == token else { return }
                self.pendingPhoto = nil
                pending.completion(.failure(ShadeError(.captureFailed, "The camera isn't ready yet. Try again in a moment.")))
            }
        }
        scheduleRender()
    }

    /// Starts recording at the full chosen resolution.
    func startRecording() throws {
        stateLock.lock()
        let size = sharedFullSize
        stateLock.unlock()
        guard let size else {
            throw ShadeError(.captureFailed, "The camera isn't ready yet. Try again in a moment.")
        }
        if let free = TemporaryFiles.availableCapacity(), free < VideoRecorder.minimumFreeBytes {
            throw ShadeError(.insufficientStorage, "Not enough free storage to record video.", detail: "\(free) bytes free")
        }
        let rec = try VideoRecorder(device: device, width: size.width, height: size.height)
        renderQueue.async { self.recorder = rec }
    }

    func stopRecording() async throws -> URL {
        let rec: VideoRecorder? = await withCheckedContinuation { continuation in
            renderQueue.async {
                let current = self.recorder
                self.recorder = nil
                continuation.resume(returning: current)
            }
        }
        guard let rec else { throw ShadeError(.captureFailed, "Nothing is being recorded.") }
        return try await rec.finish()
    }

    // MARK: Scheduling

    /// Coalesces render requests: at most one render is ever waiting on the render queue.
    private func scheduleRender() {
        stateLock.lock()
        if renderScheduled {
            stateLock.unlock()
            return
        }
        renderScheduled = true
        stateLock.unlock()
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.renderScheduled = false
            self.stateLock.unlock()
            self.renderFrame()
        }
    }

    // MARK: Rendering (render queue)

    private func renderFrame() {
        let frameRef: CVMetalTexture?
        let input: MTLTexture
        if let still = stillTexture {
            frameRef = nil
            input = still
        } else {
            stateLock.lock()
            let latest = latestFrame
            stateLock.unlock()
            guard let latest, let texture = CVMetalTextureGetTexture(latest) else { return }
            frameRef = latest
            input = texture
        }
        stateLock.lock()
        let layer = metalLayer
        let viewSize = drawableSize
        stateLock.unlock()
        guard let layer, viewSize.width > 0, viewSize.height > 0 else { return }

        // Never queue work behind a busy GPU: drop this frame instead.
        guard inFlight.wait(timeout: .now()) == .success else {
            statDropped += 1
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }

        let inputSize = PixelSize(width: input.width, height: input.height)
        let fullSize = resolution.processingSize(input: inputSize)
        let liveSize = resolution.processingSize(input: inputSize, scale: smoothMode ? governor.scale : 1)
        lastLiveSize = liveSize
        let time = Float(CACurrentMediaTime() - startTime)
        let look = prepared
        var ranCustomCode = false

        var output = input
        if !bypass, !look.passes.isEmpty, let pair = liveTargets(for: liveSize) {
            output = encode(look.passes, input: input, targets: pair, size: liveSize, time: time,
                            updateHistory: true, commandBuffer: commandBuffer, ranCustomCode: &ranCustomCode)
        }

        if let photo = pendingPhoto {
            pendingPhoto = nil
            var source = output
            if !bypass, !look.passes.isEmpty, liveSize != fullSize, let pair = makeTargets(fullSize) {
                var unused = false
                source = encode(look.passes, input: input, targets: pair, size: fullSize, time: time,
                                updateHistory: false, commandBuffer: commandBuffer, ranCustomCode: &unused)
            }
            capture(source, size: fullSize, commandBuffer: commandBuffer, completion: photo.completion)
        }

        let uniforms = Renderer.aspectFill(texture: CGSize(width: inputSize.width, height: inputSize.height), target: viewSize)
        stateLock.lock()
        sharedDisplayUniforms = uniforms
        sharedFullSize = fullSize
        stateLock.unlock()

        if let rec = recorder {
            rec.encodeFrame(from: output, commandBuffer: commandBuffer, pipeline: displayPipeline)
            checkRecorder(rec)
        }

        // Ask for the drawable last, so it is held for as short a time as possible.
        let drawable = layer.nextDrawable()
        if let drawable {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            drawProcessed(output, into: rpd, commandBuffer: commandBuffer, uniforms: uniforms)
            commandBuffer.present(drawable)
        }

        let keepAlive = frameRef
        let renderGeneration = look.generation
        let custom = ranCustomCode
        commandBuffer.addCompletedHandler { [weak self] buffer in
            _ = keepAlive // keep the camera buffer alive until the GPU is done with it
            let gpuTime = buffer.gpuEndTime - buffer.gpuStartTime
            let failed = buffer.status == .error
            let detail = failed ? String(describing: buffer.error) : ""
            guard let self else { return }
            self.inFlight.signal()
            self.renderQueue.async { self.frameFinished(gpuTime: gpuTime, failed: failed) }
            if failed {
                DispatchQueue.main.async { self.handleGPUFault(detail: detail, generation: renderGeneration, involvedCustomCode: custom) }
            }
        }
        commandBuffer.commit()
    }

    private func encode(_ passes: [PreparedPass], input: MTLTexture, targets pair: [MTLTexture], size: PixelSize, time: Float,
                        updateHistory: Bool, commandBuffer: MTLCommandBuffer, ranCustomCode: inout Bool) -> MTLTexture {
        var current = input
        var system = SystemUniforms(resolution: SIMD2(Float(size.width), Float(size.height)), time: time, mixAmount: 1)
        for (i, pass) in passes.enumerated() {
            let target = pair[i % 2]
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { break }
            enc.setRenderPipelineState(pass.pipeline)
            enc.setFragmentTexture(current, index: 0)
            if let key = pass.historyKey {
                // Feedback pass: `orig` is this pass's previous output (the current input on the first frame).
                let previous = primedHistory.contains(key) ? history[key] : nil
                enc.setFragmentTexture(previous ?? current, index: 1)
            } else {
                enc.setFragmentTexture(input, index: 1)
            }
            system.mixAmount = pass.mix
            enc.setFragmentBytes(&system, length: MemoryLayout<SystemUniforms>.stride, index: 0)
            pass.floats.withUnsafeBytes { bytes in
                enc.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            if updateHistory, let key = pass.historyKey, let store = historyTexture(for: key, like: target),
               let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: target, to: store)
                blit.endEncoding()
                primedHistory.insert(key)
            }
            current = target
            ranCustomCode = ranCustomCode || pass.isCustom
        }
        return current
    }

    private func frameFinished(gpuTime: Double, failed: Bool) {
        if !failed, gpuTime > 0 {
            statFrames += 1
            statGPUTime += gpuTime
            if smoothMode, governor.record(gpuTime: gpuTime) {
                log.info("smooth mode scale -> \(governor.scale) (avg GPU \(Int((governor.averageGPUTime ?? 0) * 1000)) ms)")
            }
        }
        let now = CACurrentMediaTime()
        let elapsed = now - statWindowStart
        guard elapsed >= 0.5 else { return }
        let stats = RenderStats(fps: Double(statFrames) / elapsed,
                                gpuMilliseconds: statFrames > 0 ? statGPUTime / Double(statFrames) * 1000 : 0,
                                processingSize: lastLiveSize,
                                scale: smoothMode ? governor.scale : 1,
                                droppedFrames: statDropped)
        statFrames = 0
        statGPUTime = 0
        statDropped = 0
        statWindowStart = now
        DispatchQueue.main.async { [weak self] in self?.onStats?(stats) }
    }

    private func checkRecorder(_ rec: VideoRecorder) {
        if let failure = rec.failure {
            recorder = nil
            rec.cancel()
            DispatchQueue.main.async { [weak self] in self?.onRecordingFailed?(failure) }
        } else if rec.duration >= VideoRecorder.maximumDuration {
            log.notice("recording reached the maximum length")
            recorder = nil
            Task { [weak self] in
                do {
                    let url = try await rec.finish()
                    DispatchQueue.main.async { self?.onRecordingReachedLimit?(url) }
                } catch {
                    let shade = ShadeError.wrap(error, as: .captureFailed, "The recording couldn't be saved.")
                    DispatchQueue.main.async { self?.onRecordingFailed?(shade) }
                }
            }
        }
    }

    // MARK: Textures (render queue)

    private func makeTargets(_ size: PixelSize) -> [MTLTexture]? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalShaderCompiler.intermediateFormat,
                                                            width: size.width, height: size.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        let pair = (0..<2).compactMap { _ in device.makeTexture(descriptor: desc) }
        if pair.count != 2 {
            log.error("could not allocate \(size) render targets")
            return nil
        }
        return pair
    }

    private func liveTargets(for size: PixelSize) -> [MTLTexture]? {
        if let t = targets.first, t.width == size.width, t.height == size.height { return targets }
        targets = makeTargets(size) ?? []
        history.removeAll()
        primedHistory.removeAll()
        return targets.count == 2 ? targets : nil
    }

    private func historyTexture(for key: UUID, like target: MTLTexture) -> MTLTexture? {
        if let existing = history[key], existing.width == target.width, existing.height == target.height { return existing }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat, width: target.width, height: target.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        let texture = device.makeTexture(descriptor: desc)
        history[key] = texture
        primedHistory.remove(key)
        return texture
    }

    // MARK: Faults (main thread)

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

    // MARK: Drawing helpers

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

    /// Renders `texture` (scaled to `size`) into a CPU-readable image.
    private func capture(_ texture: MTLTexture, size: PixelSize, commandBuffer: MTLCommandBuffer,
                         completion: @escaping (Result<UIImage, ShadeError>) -> Void) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let output = device.makeTexture(descriptor: desc) else {
            completion(.failure(ShadeError(.captureFailed, "Not enough memory to capture a photo at this resolution.")))
            return
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = output
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        drawProcessed(texture, into: rpd, commandBuffer: commandBuffer, uniforms: Renderer.identityUniforms)
        commandBuffer.addCompletedHandler { buffer in
            if buffer.status == .error {
                completion(.failure(ShadeError(.captureFailed, "The photo couldn't be captured.", detail: String(describing: buffer.error))))
            } else if let image = ImageUtils.image(fromBGRA: output) {
                completion(.success(image))
            } else {
                completion(.failure(ShadeError(.captureFailed, "The photo couldn't be captured.")))
            }
        }
    }
}
