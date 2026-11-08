import AVFoundation
import CoreVideo
import Metal
import ShadeCore

/// Records processed frames to an H.264 .mov in the temp folder (video only).
///
/// - The writer is created up front, so setup problems are reported when recording starts,
///   not discovered when it stops.
/// - Writer failures mid-recording (e.g. disk full) are exposed through `failure`; the renderer
///   checks it every frame and stops.
/// - Recordings are capped at `maximumDuration` so a forgotten recording can't fill the phone.
/// - The temp file is deleted on cancel and after saving (by `PhotoLibrarySaver`).
///
/// Threading: `encodeFrame` runs on the main thread (render loop); appends happen on a private serial queue.
final class VideoRecorder {
    static let minimumFreeBytes: Int64 = 300_000_000
    static let maximumDuration: TimeInterval = 10 * 60

    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var textureCache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "shade.video-recorder")
    private let startTime = CACurrentMediaTime()
    private let log = Log.capture

    // Guarded by `stateLock`.
    private let stateLock = NSLock()
    private var finished = false
    private var framesWritten = 0
    private var _failure: ShadeError?

    var failure: ShadeError? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _failure
    }

    var duration: TimeInterval { CACurrentMediaTime() - startTime }

    init(device: MTLDevice, width rawWidth: Int, height rawHeight: Int) throws {
        let width = rawWidth & ~1
        let height = rawHeight & ~1
        guard width >= 16, height >= 16 else {
            throw ShadeError(.captureFailed, "The camera isn't ready yet.", detail: "\(rawWidth)x\(rawHeight)")
        }
        url = TemporaryFiles.url(prefix: "Shade-", extension: "mov")
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw ShadeError(.captureFailed, "Recording couldn't start.", detail: String(describing: error))
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else {
            throw ShadeError(.captureFailed, "Recording couldn't start.", detail: "writer rejected input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ShadeError(.captureFailed, "Recording couldn't start.", detail: String(describing: writer.error))
        }
        writer.startSession(atSourceTime: .zero)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        log.info("recording started \(width)x\(height)")
    }

    func encodeFrame(from texture: MTLTexture, commandBuffer: MTLCommandBuffer, pipeline: MTLRenderPipelineState) {
        if writer.status == .failed {
            setFailure(ShadeError(.captureFailed, "Recording stopped unexpectedly. Is the iPhone out of storage?",
                                  detail: String(describing: writer.error)))
            return
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool, let cache = textureCache else { return } // drop this frame

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let pixelBuffer else { return }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard let cvTexture, let target = CVMetalTextureGetTexture(cvTexture) else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var uniforms = Renderer.identityUniforms
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Renderer.DisplayUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        let time = CMTime(seconds: duration, preferredTimescale: 600)
        let writer = self.writer, input = self.input, adaptor = self.adaptor
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard buffer.status == .completed else { return }
            self?.queue.async {
                _ = cvTexture
                guard let self, !self.isFinished, writer.status == .writing, input.isReadyForMoreMediaData else { return }
                if adaptor.append(pixelBuffer, withPresentationTime: time) {
                    self.stateLock.lock()
                    self.framesWritten += 1
                    self.stateLock.unlock()
                }
            }
        }
    }

    /// Finishes the file and returns its URL. Throws if nothing was recorded or writing failed.
    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async {
                self.stateLock.lock()
                self.finished = true
                let frames = self.framesWritten
                self.stateLock.unlock()

                guard self.writer.status == .writing, frames > 0 else {
                    let detail = "status \(self.writer.status.rawValue), frames \(frames), \(String(describing: self.writer.error))"
                    self.discard()
                    continuation.resume(throwing: ShadeError(.captureFailed, "The recording was empty or failed.", detail: detail))
                    return
                }
                self.input.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        self.log.info("recording finished: \(frames) frames")
                        continuation.resume(returning: self.url)
                    } else {
                        let detail = String(describing: self.writer.error)
                        self.discard()
                        continuation.resume(throwing: ShadeError(.captureFailed, "The recording couldn't be saved.", detail: detail))
                    }
                }
            }
        }
    }

    /// Stops without saving and deletes the temp file.
    func cancel() {
        queue.async {
            self.stateLock.lock()
            self.finished = true
            self.stateLock.unlock()
            self.discard()
        }
    }

    private var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finished
    }

    private func setFailure(_ error: ShadeError) {
        stateLock.lock()
        if _failure == nil { _failure = error }
        stateLock.unlock()
        log.error("recording failed: \(error)")
    }

    private func discard() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
