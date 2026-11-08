import Foundation

/// Request/response shapes for `POST /v1/messages`, limited to what Shade uses.
public struct ClaudeMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var content: [JSONValue]

    public init(role: Role, content: [JSONValue]) {
        self.role = role
        self.content = content
    }

    public static func user(_ blocks: [JSONValue]) -> ClaudeMessage { ClaudeMessage(role: .user, content: blocks) }

    public static func text(_ text: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(text)])
    }

    public static func jpeg(_ data: Data) -> JSONValue {
        .object([
            "type": .string("image"),
            "source": .object([
                "type": .string("base64"),
                "media_type": .string("image/jpeg"),
                "data": .string(data.base64EncodedString())
            ])
        ])
    }
}

public struct MessagesRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var maxTokens: Int
    public var system: String
    public var messages: [ClaudeMessage]
    public var effort: String?
    /// `"default"` opts into server-side refusal fallbacks (needs the beta header, added by the client).
    public var fallbacks: String?

    public init(model: String, maxTokens: Int = 16_000, system: String, messages: [ClaudeMessage], effort: String? = nil, fallbacks: String? = nil) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.effort = effort
        self.fallbacks = fallbacks
    }

    enum CodingKeys: String, CodingKey {
        case model, maxTokens = "max_tokens", system, messages, outputConfig = "output_config", fallbacks
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(maxTokens, forKey: .maxTokens)
        // The system prompt (the recipe spec) is large and identical on every call: cache it.
        let systemBlock: JSONValue = .object([
            "type": .string("text"),
            "text": .string(system),
            "cache_control": .object(["type": .string("ephemeral")])
        ])
        try c.encode([systemBlock], forKey: .system)
        try c.encode(messages, forKey: .messages)
        if let effort { try c.encode(["effort": effort], forKey: .outputConfig) }
        try c.encodeIfPresent(fallbacks, forKey: .fallbacks)
    }
}

public struct MessagesResponse: Decodable, Equatable, Sendable {
    public var id: String?
    public var model: String?
    public var content: [JSONValue]
    public var stopReason: String?
    public var stopDetails: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, model, content, stopReason = "stop_reason", stopDetails = "stop_details"
    }

    public init(id: String? = nil, model: String? = nil, content: [JSONValue], stopReason: String?, stopDetails: JSONValue? = nil) {
        self.id = id
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.stopDetails = stopDetails
    }

    /// The visible text (thinking blocks and other block types are skipped).
    public var text: String {
        content.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }.joined(separator: "\n")
    }

    /// The assistant turn to append when continuing the conversation, replaying every block unchanged.
    public var asAssistantMessage: ClaudeMessage { ClaudeMessage(role: .assistant, content: content) }
}

/// The API's error body: `{"type":"error","error":{"type":"...","message":"..."}}`.
struct APIErrorBody: Decodable {
    struct Inner: Decodable {
        let type: String?
        let message: String?
    }
    let error: Inner?
}
