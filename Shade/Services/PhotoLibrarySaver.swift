import Photos
import ShadeCore
import UIKit

/// Saves captures to the photo library with add-only permission (Shade never reads the library).
enum PhotoLibrarySaver {
    static func save(image: UIImage) async throws {
        try await perform { _ = PHAssetChangeRequest.creationRequestForAsset(from: image) }
        Log.capture.info("photo saved")
    }

    /// Saves a movie and always deletes the temporary file afterwards, whether or not saving worked.
    static func save(videoAt url: URL) async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try await perform { _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
        Log.capture.info("video saved")
    }

    private static func perform(_ change: @escaping @Sendable () -> Void) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ShadeError(.photosDenied, "Shade isn't allowed to add to your photo library. Turn it on in Settings → Shade → Photos.")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges(change)
        } catch {
            throw ShadeError(.captureFailed, "Couldn't save to your photo library.", detail: String(describing: error))
        }
    }
}
