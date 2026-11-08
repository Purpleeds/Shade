import Foundation
#if canImport(os)
import os
#endif

/// Structured, privacy-aware logging. On Apple platforms this goes to the unified log
/// (Console.app, filter on subsystem `com.shadeapp.shade`). Elsewhere (Linux CI) it is silent.
///
/// Rules: never log the API key, request bodies, image data or recipe code. Log identifiers,
/// error codes, HTTP status, request ids and durations.
public struct Log: Sendable {
    public let category: String

    public static let storage = Log(category: "storage")
    public static let claude = Log(category: "claude")
    public static let generation = Log(category: "generation")
    public static let shaders = Log(category: "shaders")
    public static let render = Log(category: "render")
    public static let camera = Log(category: "camera")
    public static let capture = Log(category: "capture")
    public static let migration = Log(category: "migration")

    public static let subsystem = "com.shadeapp.shade"

    public init(category: String) { self.category = category }

    public func info(_ message: String) { emit(.info, message) }
    public func notice(_ message: String) { emit(.notice, message) }
    public func warning(_ message: String) { emit(.warning, message) }
    public func error(_ message: String) { emit(.error, message) }

    public func error(_ message: String, _ error: Error) {
        emit(.error, "\(message): \(String(describing: error))")
    }

    enum Level { case info, notice, warning, error }

    private func emit(_ level: Level, _ message: String) {
        #if canImport(os)
        let logger = Logger(subsystem: Log.subsystem, category: category)
        // Messages are built by our own code from identifiers and codes, never secrets, so public is fine.
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        #endif
    }
}
