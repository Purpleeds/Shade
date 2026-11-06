import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A movie picked from Photos, copied into our temp directory.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
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

    /// Loads up to `maxImages` images from a PhotosPicker selection; videos contribute evenly spaced frames.
    static func load(from items: [PhotosPickerItem], maxImages: Int = 8) async throws -> ReferenceMedia {
        var media = ReferenceMedia()
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            if isVideo, let movie = try await item.loadTransferable(type: PickedMovie.self) {
                defer { try? FileManager.default.removeItem(at: movie.url) }
                let frames = try await frames(from: movie.url, count: 4)
                media.images.append(contentsOf: frames)
                media.videoFrameCount += frames.count
            } else if let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                media.images.append(ImageUtils.resized(image, maxDimension: 1568))
            }
        }
        media.images = Array(media.images.prefix(maxImages))
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
        var images: [UIImage] = []
        let safeDuration = duration.isFinite && duration > 0 ? duration : 1
        for i in 0..<count {
            let t = safeDuration * (Double(i) + 0.5) / Double(count)
            if let cg = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                images.append(UIImage(cgImage: cg))
            }
        }
        return images
    }
}
