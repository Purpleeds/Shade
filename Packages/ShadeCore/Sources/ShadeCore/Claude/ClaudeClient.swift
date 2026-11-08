import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anything that can answer a Messages request. The generator depends on this, not on HTTP.
public protocol ClaudeMessaging: Sendable {
    func send(_ request: MessagesRequest) async throws -> MessagesResponse
}

/// Calls the Claude Messages API over HTTPS. There is no official Swift SDK, so this speaks the
/// documented REST shape directly.
///
/// Security: the key travels only in the `x-api-key` header to `api.anthropic.com` over TLS
/// (system trust, no overrides). It is validated before use and never logged.
public struct ClaudeClient: ClaudeMessaging {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let apiKey: String
    private let transport: HTTPTransport
    private let retry: RetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let log = Log.claude

    public init(apiKey: String,
                transport: HTTPTransport = URLSessionTransport(),
                retry: RetryPolicy = RetryPolicy(),
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) throws {
        self.apiKey = try ClaudeClient.validatedKey(apiKey)
        self.transport = transport
        self.retry = retry
        self.sleep = sleep
    }

    /// Rejects keys that are empty or contain characters that could break or inject into the HTTP header.
    public static func validatedKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ShadeError(.claudeMissingKey, "Add your Claude API key in Settings first (create one at console.anthropic.com).")
        }
        let allowed = key.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }
        guard allowed, key.count <= 256 else {
            throw ShadeError(.claudeInvalidKey, "That doesn't look like a Claude API key. Copy it again from console.anthropic.com.")
        }
        return key
    }

    func makeURLRequest(_ request: MessagesRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: ClaudeClient.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(ClaudeClient.apiVersion, forHTTPHeaderField: "anthropic-version")
        if request.fallbacks != nil {
            urlRequest.setValue(ClaudeClient.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw ShadeError(.claudeBadRequest, "Couldn't build the request to Claude.", detail: String(describing: error))
        }
        return urlRequest
    }

    public func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        let urlRequest = try makeURLRequest(request)
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let started = Date()
            do {
                let response = try await sendOnce(urlRequest)
                log.info("messages ok model=\(request.model) id=\(response.id ?? "?") stop=\(response.stopReason ?? "?") \(Self.ms(since: started))ms attempt=\(attempt)")
                return response
            } catch let error as RetryableFailure {
                log.warning("messages attempt \(attempt) failed: \(error.error) \(Self.ms(since: started))ms")
                guard attempt < retry.maxAttempts else { throw error.error }
                let wait = retry.delay(afterAttempt: attempt, retryAfter: error.retryAfter)
                try await sleep(wait)
                attempt += 1
            }
        }
    }

    /// Internal marker for failures the retry loop may repeat.
    struct RetryableFailure: Error {
        let error: ShadeError
        let retryAfter: TimeInterval?
    }

    private func sendOnce(_ urlRequest: URLRequest) async throws -> MessagesResponse {
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(urlRequest)
        } catch is CancellationError {
            throw ShadeError(.cancelled, "Cancelled.")
        } catch let error as ShadeError {
            throw error
        } catch let error as URLError {
            throw ClaudeClient.classify(error)
        } catch {
            throw ShadeError(.networkUnavailable, "Couldn't reach Claude. Check your internet connection.", detail: String(describing: error))
        }

        let requestID = http.value(forHTTPHeaderField: "request-id") ?? "-"
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(APIErrorBody.self, from: data)
            let apiMessage = body?.error?.message ?? ""
            let detail = "HTTP \(http.statusCode) \(body?.error?.type ?? "") request-id=\(requestID) \(apiMessage)"
            let error = ClaudeClient.errorFor(status: http.statusCode, apiMessage: apiMessage, detail: detail)
            if RetryPolicy.isRetryable(status: http.statusCode) {
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
                throw RetryableFailure(error: error, retryAfter: retryAfter)
            }
            log.error("messages failed: \(error)")
            throw error
        }

        let response: MessagesResponse
        do {
            response = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw ShadeError(.claudeBadResponse, "Claude sent a response Shade couldn't read.",
                             detail: "request-id=\(requestID) \(error)")
        }
        if response.stopReason == "refusal" {
            let explanation = response.stopDetails?["explanation"]?.stringValue
            throw ShadeError(.claudeRefused, "Claude declined this request." + (explanation.map { " \($0)" } ?? ""),
                             detail: "request-id=\(requestID) category=\(response.stopDetails?["category"]?.stringValue ?? "-")")
        }
        return response
    }

    static func classify(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled:
            return ShadeError(.cancelled, "Cancelled.")
        case .timedOut:
            return RetryableFailure(error: ShadeError(.networkTimeout, "Claude took too long to respond. Try again, or lower the effort in Settings.",
                                                      detail: String(describing: error)), retryAfter: nil)
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed:
            return RetryableFailure(error: ShadeError(.networkUnavailable, "Couldn't reach Claude. Check your internet connection.",
                                                      detail: String(describing: error)), retryAfter: nil)
        default:
            return ShadeError(.networkUnavailable, "Couldn't reach Claude.", detail: String(describing: error))
        }
    }

    static func errorFor(status: Int, apiMessage: String, detail: String) -> ShadeError {
        switch status {
        case 400: return ShadeError(.claudeBadRequest, "Claude rejected the request: \(apiMessage)", detail: detail)
        case 401: return ShadeError(.claudeUnauthorized, "Your API key was rejected. Check it in Settings.", detail: detail)
        case 403: return ShadeError(.claudeForbidden, "This API key can't use the selected model. Pick another model in Settings.", detail: detail)
        case 404: return ShadeError(.claudeBadRequest, "The selected model isn't available. Pick another model in Settings.", detail: detail)
        case 413: return ShadeError(.claudeRequestTooLarge, "The images are too large for one request. Use fewer or smaller images.", detail: detail)
        case 429: return ShadeError(.claudeRateLimited, "You've hit your Claude API rate limit. Wait a minute and try again.", detail: detail)
        case 529: return ShadeError(.claudeOverloaded, "Claude is overloaded right now. Try again in a minute.", detail: detail)
        case 408: return ShadeError(.networkTimeout, "The request to Claude timed out. Try again.", detail: detail)
        case 500...599: return ShadeError(.claudeServerError, "The Claude API is having trouble. Try again shortly.", detail: detail)
        default: return ShadeError(.claudeBadResponse, "Unexpected error from the Claude API (\(status)).", detail: detail)
        }
    }

    private static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}
