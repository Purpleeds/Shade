import AVFoundation
import CoreVideo
import Metal

/// Records the processed frames to an H.264 .mov file (video only).
/// `encodeFrame` is called from the render loop (main thread); appends happen on a private serial queue.
final class VideoRecorder {
    let url: URL
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "shade.video-recorder")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CFTimeInterval = 0
    private var finished = false // only touched on `queue`
    private(set) var framesWritten = 0

    init(device: MTLDevice) throws {
        self.device = device
        url = FileManager.default.temporaryDirectory.appendingPathComponent("Shade-\(UUID().uuidString).mov")
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    private func setUp(width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        startTime = CACurrentMediaTime()
    }

    func encodeFrame(from texture: MTLTexture, commandBuffer: MTLCommandBuffer, pipeline: MTLRenderPipelineState) {
        if writer == nil {
            do { try setUp(width: texture.width & ~1, height: texture.height & ~1) } catch { return }
        }
        guard let writer, let input, let adaptor, writer.status == .writing, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool, let cache = textureCache else { return }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let pixelBuffer else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
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

        let time = CMTime(seconds: CACurrentMediaTime() - startTime, preferredTimescale: 600)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                _ = cvTexture
                guard !self.finished, writer.status == .writing, input.isReadyForMoreMediaData else { return }
                if adaptor.append(pixelBuffer, withPresentationTime: time) { self.framesWritten += 1 }
            }
        }
    }

    /// Finishes the file. `completion` gets the movie URL (or nil if nothing was recorded) on the main thread.
    func finish(_ completion: @escaping (URL?) -> Void) {
        queue.async {
            self.finished = true
            guard let writer = self.writer, let input = self.input, writer.status == .writing, self.framesWritten > 0 else {
                self.writer?.cancelWriting()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            input.markAsFinished()
            let url = self.url
            writer.finishWriting {
                let ok = writer.status == .completed
                DispatchQueue.main.async { completion(ok ? url : nil) }
            }
        }
    }
}
