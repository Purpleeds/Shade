import Foundation

/// Retries for the Claude API, applied at exactly one layer (the client).
///
/// Retried: 408, 429, 500, 502, 503, 504, 529 and transient network errors.
/// Not retried: other 4xx (the request itself is wrong, repeating it can't help).
/// Delay: exponential backoff with full jitter, or the server's `retry-after` if it asks for longer, capped.
///
/// Note on replay: a retried request after a dropped connection may already have been processed and
/// billed. Generations are stateless, so the only cost is a duplicate (cents), never corrupted state.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 1.5, maxDelay: TimeInterval = 30) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    public static func isRetryable(status: Int) -> Bool {
        [408, 429, 500, 502, 503, 504, 529].contains(status)
    }

    /// Delay before attempt `attempt + 1` (attempt is 1-based). `random` is injectable for tests.
    public func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?, random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> TimeInterval {
        let exponential = min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
        let jittered = random(0...1) * exponential
        if let retryAfter, retryAfter > 0 { return min(maxDelay, max(retryAfter, jittered)) }
        return max(0.1, jittered)
    }
}
