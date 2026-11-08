import Foundation
import ShadeCore

/// Temporary files Shade creates (recordings, picked videos, share exports) contain the user's camera
/// footage, so they are cleaned up deliberately instead of waiting for iOS to purge the tmp folder.
enum TemporaryFiles {
    static let prefixes = ["Shade-", "picked-", "share-"]

    static func url(prefix: String, extension ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString).\(ext)")
    }

    /// Removes leftovers from previous runs (e.g. a recording interrupted by a crash).
    static func sweep(olderThan age: TimeInterval = 600) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var removed = 0
        for url in items where prefixes.contains(where: url.lastPathComponent.hasPrefix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(modified) > age, (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 { Log.capture.info("removed \(removed) stale temporary file(s)") }
    }

    /// Free space available for large writes like recordings, in bytes.
    static func availableCapacity() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
