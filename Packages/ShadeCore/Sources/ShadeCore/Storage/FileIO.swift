import Foundation

/// Small, strict file helpers shared by the stores. All writes are atomic (write to a temp file,
/// then rename), so a crash or a full disk never leaves a half-written recipe or state file behind.
enum FileIO {
    static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw ShadeError(.storageWriteFailed, "Shade couldn't create its storage folder.",
                             detail: "\(url.lastPathComponent) exists and is not a directory")
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ShadeError(.storageWriteFailed, "Shade couldn't create its storage folder.", detail: String(describing: error))
        }
    }

    /// Reads a file, refusing anything larger than `limit` before loading it into memory.
    static func read(_ url: URL, limit: Int, fileManager: FileManager) throws -> Data {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > limit {
            throw ShadeError(.recipeTooLarge, "\(url.lastPathComponent) is too large to be a recipe.", detail: "\(size) bytes")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ShadeError(.storageReadFailed, "\(url.lastPathComponent) couldn't be read.", detail: String(describing: error))
        }
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: [.atomic])
            #endif
        } catch {
            throw ShadeError(.storageWriteFailed, "Shade couldn't save \(url.lastPathComponent). Is the iPhone out of storage?",
                             detail: String(describing: error))
        }
    }

    static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
