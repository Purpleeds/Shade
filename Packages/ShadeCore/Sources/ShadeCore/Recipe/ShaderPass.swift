import Foundation

/// One full-screen shader pass. Either references a built-in effect (`effect`) or carries custom
/// Metal code (`code`) that defines a `shade(...)` function. Passes run in order; each pass
/// receives the previous pass's output.
///
/// `id` is a runtime identity for SwiftUI lists. It is not part of the file format.
public struct ShaderPass: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String?
    public var effect: String?
    public var code: String?
    public var params: [ShaderParam] = []
    public var enabled = true
    /// Blend between the pass input (0) and the pass output (1).
    public var mix: Float = 1

    public init(name: String? = nil, effect: String? = nil, code: String? = nil, params: [ShaderParam] = [],
                enabled: Bool = true, mix: Float = 1) {
        self.name = name
        self.effect = effect
        self.code = code
        self.params = params
        self.enabled = enabled
        self.mix = mix
        normalize()
    }

    /// Convenience for presets: a built-in effect with some parameter overrides.
    public static func builtIn(_ effect: String, _ overrides: [String: [Float]] = [:], mix: Float = 1) -> ShaderPass {
        var pass = ShaderPass(effect: effect, mix: mix)
        for (key, value) in overrides {
            if let i = pass.params.firstIndex(where: { $0.name == key }) {
                pass.params[i].value = value
                pass.params[i].normalize()
            }
        }
        return pass
    }

    public var hasCustomCode: Bool {
        guard let code else { return false }
        return !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True for custom-code passes and for passes whose effect isn't a known built-in.
    public var isCustom: Bool { builtInEffect == nil }

    public var builtInEffect: BuiltInEffect? {
        guard !hasCustomCode, let effect else { return nil }
        return BuiltInEffects.find(effect)
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let fx = builtInEffect { return fx.displayName }
        if let effect, !effect.isEmpty { return effect }
        return "Custom shader"
    }

    /// Canonicalises the pass: resolves built-in effect aliases, fills in built-in parameter definitions
    /// (keeping values already provided), dedupes custom parameter names and clamps values.
    /// Never drops data silently; limits are enforced by `RecipeValidator`.
    public mutating func normalize() {
        if !mix.isFinite { mix = 1 }
        mix = Swift.min(Swift.max(mix, 0), 1)
        if !hasCustomCode { code = nil }

        if let fx = builtInEffect {
            effect = fx.id
            let provided = params
            params = fx.params.map { def in
                var p = def
                if let given = provided.first(where: { $0.name.caseInsensitiveCompare(def.name) == .orderedSame }) {
                    p.value = given.value
                    if def.kind == .float {
                        // Recipes may widen a built-in's slider range when they need to.
                        if given.min < def.min { p.min = given.min }
                        if given.max > def.max { p.max = given.max }
                    }
                }
                p.normalize()
                return p
            }
        } else {
            var seen = Set<String>()
            params = params.map { param in
                var p = param
                p.normalize()
                var candidate = p.name
                var n = 2
                while seen.contains(candidate) { candidate = "\(p.name)\(n)"; n += 1 }
                p.name = candidate
                seen.insert(candidate)
                return p
            }
        }
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case name, effect, code, params, enabled, mix
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        effect = try c.decodeIfPresent(String.self, forKey: .effect)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mix = try c.decodeIfPresent(Float.self, forKey: .mix) ?? 1
        if try !c.contains(.params) || c.decodeNil(forKey: .params) {
            params = []
        } else if let list = try? c.decode([ShaderParam].self, forKey: .params) {
            params = list
        } else {
            // Shorthand used for built-in effects: { "levels": 4, "color": "#000000" }.
            // Decoding this one without `try?` so a malformed value reports a useful error path.
            let dict = try c.decode([String: FlexibleValue].self, forKey: .params)
            params = dict.keys.sorted().map { key in
                let v = dict[key]!
                let first = v.components.first ?? 0
                return ShaderParam(name: key, kind: v.components.count >= 3 ? .color : .float, value: v.components,
                                   min: Swift.min(0, first), max: Swift.max(1, first * 2))
            }
        }
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        if builtInEffect != nil {
            try c.encode(effect, forKey: .effect)
            // Built-ins only need their values; the app knows the ranges.
            var dict: [String: FlexibleValue] = [:]
            for p in params { dict[p.name] = FlexibleValue(p.value) }
            try c.encode(dict, forKey: .params)
        } else {
            try c.encodeIfPresent(effect, forKey: .effect)
            try c.encodeIfPresent(code, forKey: .code)
            try c.encode(params, forKey: .params)
        }
        if !enabled { try c.encode(enabled, forKey: .enabled) }
        if mix < 1 { try c.encode(mix, forKey: .mix) }
    }
}
