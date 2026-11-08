import AVFoundation
import CoreTransferable
import PhotosUI
import ShadeCore
import SwiftUI
import UniformTypeIdentifiers

/// A movie picked from Photos, copied into our temp directory (and deleted after frames are taken).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = TemporaryFiles.url(prefix: "picked-", extension: ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Reference material for style generation: still images plus frames sampled from videos.
struct ReferenceMedia {
    var images: [UIImage] = []
    var videoFrameCount = 0
    var isEmpty: Bool { images.isEmpty }

    static let framesPerVideo = 4

    /// Loads a PhotosPicker selection. Videos contribute evenly spaced frames. Items that fail to load
    /// are reported instead of silently dropped.
    static func load(from items: [PhotosPickerItem]) async throws -> ReferenceMedia {
        var media = ReferenceMedia()
        var failures = 0
        for item in items {
            try Task.checkCancellation()
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            do {
                if isVideo {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { failures += 1; continue }
                    defer { try? FileManager.default.removeItem(at: movie.url) }
                    let frames = try await frames(from: movie.url, count: framesPerVideo)
                    media.images.append(contentsOf: frames)
                    media.videoFrameCount += frames.count
                } else if let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    media.images.append(ImageUtils.resized(image, maxDimension: 1568))
                } else {
                    failures += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.generation.warning("couldn't load a picked item: \(error)")
                failures += 1
            }
        }
        if media.images.count > GenerationRequest.maxImages {
            media.images = Array(media.images.prefix(GenerationRequest.maxImages))
            media.videoFrameCount = min(media.videoFrameCount, media.images.count)
        }
        if media.isEmpty && failures > 0 {
            throw ShadeError(.generationInvalidInput, "Couldn't load that selection. If it's in iCloud, wait for it to download and try again.")
        }
        return media
    }

    static func frames(from url: URL, count: Int) async throws -> [UIImage] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1568, height: 1568)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let safeDuration = duration.isFinite && duration > 0 ? duration : 1
        var images: [UIImage] = []
        for i in 0..<count {
            let t = safeDuration * (Double(i) + 0.5) / Double(count)
            if let cg = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                images.append(UIImage(cgImage: cg))
            }
        }
        if images.isEmpty {
            throw ShadeError(.generationInvalidInput, "Couldn't read frames from that video.")
        }
        return images
    }

    /// Converts to a generation request (JPEG encoding happens here, once).
    func generationRequest(notes: String) throws -> GenerationRequest {
        GenerationRequest(images: try images.map(ImageUtils.jpegForClaude), videoFrameCount: videoFrameCount, notes: notes)
    }
}
