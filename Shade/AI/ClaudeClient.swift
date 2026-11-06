import Foundation

/// Calls the Claude Messages API over HTTPS (there is no official Swift SDK, so this uses URLSession directly).
struct ClaudeClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"

    struct ModelOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let models: [ModelOption] = [
        ModelOption(id: "claude-opus-5-5", name: "Claude Opus 5.5 (best default)"),
        ModelOption(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5 (faster, cheaper)"),
        ModelOption(id: "claude-fable-5-1", name: "Claude Fable 5.1 (most capable, priciest)"),
        ModelOption(id: "claude-haiku-5-5", name: "Claude Haiku 5.5 (fastest, cheapest)")
    ]

    static func displayName(for model: String) -> String {
        models.first { $0.id == model }?.name ?? model
    }
    static let defaultModel = "claude-opus-5-5"
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    static let defaultEffort = "high"

    /// Models that support server-side refusal fallbacks (`fallbacks: "default"`).
    static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-opus-5"]

    struct Reply {
        /// The raw content blocks, replayed unchanged on follow-up turns (thinking blocks included).
        let content: [[String: Any]]
        let text: String
        let stopReason: String?
    }

    enum ClientError: LocalizedError {
        case missingKey
        case http(Int, String)
        case refused(String?)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Add your Claude API key in Settings first (get one at console.anthropic.com)."
            case .http(let status, let message):
                switch status {
                case 401: return "The API key was rejected (401). Check it in Settings."
                case 403: return "This API key doesn't have access to that model (403). \(message)"
                case 413: return "The images were too large for one request. Try fewer or smaller images."
                case 429: return "Rate limited by the Claude API (429). Wait a moment and try again."
                case 500...599: return "The Claude API is having trouble (\(status)). Try again shortly. \(message)"
                default: return "Claude API error \(status): \(message)"
                }
            case .refused(let explanation):
                return "Claude declined this request." + (explanation.map { " \($0)" } ?? "")
            case .badResponse:
                return "Unexpected response from the Claude API."
            }
        }
    }

    var apiKey: String
    var model: String = defaultModel
    var effort: String = defaultEffort

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    func send(system: String, messages: [[String: Any]], maxTokens: Int = 16000) async throws -> Reply {
        guard !apiKey.isEmpty else { throw ClientError.missingKey }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            // The spec is large and identical every call, so cache it.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages,
            "output_config": ["effort": effort]
        ]
        var request = URLRequest(url: ClaudeClient.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ClaudeClient.apiVersion, forHTTPHeaderField: "anthropic-version")
        if ClaudeClient.fallbackModels.contains(model) {
            // If a safety classifier declines, the API retries on a suitable fallback model automatically.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await ClaudeClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200..<300).contains(http.statusCode) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(decoding: data.prefix(500), as: UTF8.self)
            throw ClientError.http(http.statusCode, message)
        }
        guard let json, let content = json["content"] as? [[String: Any]] else { throw ClientError.badResponse }

        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw ClientError.refused(details?["explanation"] as? String)
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return Reply(content: content, text: text, stopReason: stopReason)
    }

    static func imageBlock(jpeg: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }

    static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }
}
