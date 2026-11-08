import Foundation

/// Which model and effort the user picked, validated so a stale or tampered value can't reach the API.
public struct GenerationSettings: Equatable, Sendable {
    public struct ModelOption: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        /// Whether the API supports `fallbacks: "default"` (server-side refusal fallback) for this model.
        public let supportsServerFallback: Bool
    }

    public static let models: [ModelOption] = [
        ModelOption(id: "claude-opus-5-5", name: "Claude Opus 5.5 (best default)", supportsServerFallback: true),
        ModelOption(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5 (faster, cheaper)", supportsServerFallback: true),
        ModelOption(id: "claude-fable-5-1", name: "Claude Fable 5.1 (most capable, priciest)", supportsServerFallback: true),
        ModelOption(id: "claude-haiku-5-5", name: "Claude Haiku 5.5 (fastest, cheapest)", supportsServerFallback: false)
    ]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
    public static let defaultModel = "claude-opus-5-5"
    public static let defaultEffort = "high"

    public static let modelDefaultsKey = "claudeModel"
    public static let effortDefaultsKey = "claudeEffort"

    public let model: ModelOption
    public let effort: String

    /// Unknown values fall back to the defaults rather than failing.
    public init(model: String?, effort: String?) {
        self.model = GenerationSettings.models.first { $0.id == model }
            ?? GenerationSettings.models.first { $0.id == GenerationSettings.defaultModel }!
        self.effort = effort.flatMap { GenerationSettings.efforts.contains($0) ? $0 : nil } ?? GenerationSettings.defaultEffort
    }

    public static func load(from defaults: UserDefaults) -> GenerationSettings {
        GenerationSettings(model: defaults.string(forKey: modelDefaultsKey), effort: defaults.string(forKey: effortDefaultsKey))
    }

    public static func displayName(for model: String) -> String {
        models.first { $0.id == model }?.name ?? model
    }
}
