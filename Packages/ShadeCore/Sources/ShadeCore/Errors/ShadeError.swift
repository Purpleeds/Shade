import Foundation

/// The one error type that crosses module boundaries.
///
/// - `code` is stable: UI and tests branch on it, never on message text.
/// - `message` is written for the person using the app.
/// - `detail` is for logs (underlying error, file name, HTTP request id). It is never shown as the main message.
public struct ShadeError: Error, LocalizedError, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, CaseIterable {
        // Recipe input (caller's fault: bad file, bad paste, bad Claude output)
        case recipeNotFound = "recipe.not_found"
        case recipeInvalidJSON = "recipe.invalid_json"
        case recipeUnsupportedFormat = "recipe.unsupported_format"
        case recipeInvalid = "recipe.invalid"
        case recipeTooLarge = "recipe.too_large"
        // Storage (system's fault)
        case storageReadFailed = "storage.read_failed"
        case storageWriteFailed = "storage.write_failed"
        case storageDeleteFailed = "storage.delete_failed"
        // Claude API
        case claudeMissingKey = "claude.missing_key"
        case claudeInvalidKey = "claude.invalid_key"
        case claudeUnauthorized = "claude.unauthorized"
        case claudeForbidden = "claude.forbidden"
        case claudeBadRequest = "claude.bad_request"
        case claudeRequestTooLarge = "claude.request_too_large"
        case claudeRateLimited = "claude.rate_limited"
        case claudeOverloaded = "claude.overloaded"
        case claudeServerError = "claude.server_error"
        case claudeRefused = "claude.refused"
        case claudeTruncated = "claude.truncated"
        case claudeBadResponse = "claude.bad_response"
        case networkUnavailable = "network.unavailable"
        case networkTimeout = "network.timeout"
        // Generation
        case generationInvalidInput = "generation.invalid_input"
        case generationFailed = "generation.failed"
        case cancelled = "cancelled"
        // Device
        case shaderCompileFailed = "shader.compile_failed"
        case gpuFault = "gpu.fault"
        case cameraDenied = "camera.denied"
        case cameraUnavailable = "camera.unavailable"
        case captureFailed = "capture.failed"
        case photosDenied = "photos.denied"
        case insufficientStorage = "device.insufficient_storage"
    }

    public let code: Code
    public let message: String
    public let detail: String?

    public init(_ code: Code, _ message: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    public var errorDescription: String? { message }

    public var description: String {
        detail.map { "[\(code.rawValue)] \(message) (\($0))" } ?? "[\(code.rawValue)] \(message)"
    }

    /// Whether repeating the same operation could succeed without the user changing anything.
    public var isTransient: Bool {
        switch code {
        case .claudeRateLimited, .claudeOverloaded, .claudeServerError, .networkUnavailable, .networkTimeout:
            return true
        default:
            return false
        }
    }

    /// Wraps any error as a ShadeError, keeping ShadeErrors as they are.
    public static func wrap(_ error: Error, as code: Code, _ message: String) -> ShadeError {
        if let shade = error as? ShadeError { return shade }
        if error is CancellationError { return ShadeError(.cancelled, "Cancelled.") }
        return ShadeError(code, message, detail: String(describing: error))
    }
}
