import Foundation

// MARK: - Parameters

/// A tweakable value exposed by a shader pass. Floats become sliders, colors become color pickers.
/// Inside Metal code every parameter is available as `P.<name>` (`float` or `packed_float3`).
struct ShaderParam: Codable, Hashable {
    enum Kind: String, Codable {
        case float
        case color
    }

    var name: String
    var kind: Kind
    /// One component for `.float`, three (r, g, b in 0...1) for `.color`.
    var value: [Float]
    var min: Float
    var max: Float
    var label: String?

    init(name: String, kind: Kind, value: [Float], min: Float = 0, max: Float = 1, label: String? = nil) {
        self.name = name
        self.kind = kind
        self.value = value
        self.min = min
        self.max = max
        self.label = label
        normalize()
    }

    static func float(_ name: String, _ value: Float, _ min: Float, _ max: Float, label: String? = nil) -> ShaderParam {
        ShaderParam(name: name, kind: .float, value: [value], min: min, max: max, label: label)
    }

    static func color(_ name: String, _ r: Float, _ g: Float, _ b: Float, label: String? = nil) -> ShaderParam {
        ShaderParam(name: name, kind: .color, value: [r, g, b], min: 0, max: 1, label: label)
    }

    var componentCount: Int { kind == .color ? 3 : 1 }

    var scalar: Float {
        get { value.first ?? 0 }
        set { value = [newValue] }
    }

    var displayName: String {
        if let label, !label.isEmpty { return label }
        return ShaderParam.humanize(name)
    }

    /// Makes the parameter safe to feed into Metal and SwiftUI (valid identifier, sane range, right arity).
    mutating func normalize() {
        name = ShaderParam.sanitizeIdentifier(name)
        if !min.isFinite { min = 0 }
        if !max.isFinite { max = 1 }
        if max < min { swap(&min, &max) }
        if max - min < 0.0001 { max = min + 1 }
        value = value.map { $0.isFinite ? $0 : 0 }
        switch kind {
        case .float:
            if value.isEmpty { value = [min] }
            if value.count > 1 { value = [value[0]] }
            value[0] = Swift.min(Swift.max(value[0], min), max)
        case .color:
            min = 0
            max = 1
            if value.count == 1 { value = [value[0], value[0], value[0]] }
            while value.count < 3 { value.append(0) }
            if value.count > 3 { value = Array(value.prefix(3)) }
            // Accept 0...255 colors as well.
            if value.contains(where: { $0 > 1.0001 }) { value = value.map { $0 / 255 } }
            value = value.map { Swift.min(Swift.max($0, 0), 1) }
        }
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case name, type, value, min, max, label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        let decodedValue = try c.decodeIfPresent(FlexibleValue.self, forKey: .value)
        let explicitKind = try c.decodeIfPresent(String.self, forKey: .type).flatMap { Kind(rawValue: $0.lowercased()) }
        let components = decodedValue?.components ?? [0]
        kind = explicitKind ?? (components.count >= 3 || decodedValue?.isColorString == true ? .color : .float)
        value = components
        let v = components.first ?? 0
        min = try c.decodeIfPresent(Float.self, forKey: .min) ?? Swift.min(0, v)
        max = try c.decodeIfPresent(Float.self, forKey: .max) ?? Swift.max(1, v * 2)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind.rawValue, forKey: .type)
        switch kind {
        case .float:
            try c.encode(scalar, forKey: .value)
            try c.encode(min, forKey: .min)
            try c.encode(max, forKey: .max)
        case .color:
            try c.encode(value, forKey: .value)
        }
        try c.encodeIfPresent(label, forKey: .label)
    }

    // MARK: Helpers

    static let reservedWords: Set<String> = [
        "float", "half", "int", "uint", "bool", "char", "short", "long", "double", "void", "true", "false",
        "if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case", "default",
        "struct", "class", "union", "enum", "const", "constant", "device", "thread", "threadgroup",
        "static", "inline", "kernel", "vertex", "fragment", "sampler", "texture", "using", "namespace",
        "template", "typename", "this", "new", "delete", "auto", "register", "volatile", "extern",
        "signed", "unsigned", "sizeof", "operator", "private", "public", "protected", "virtual",
        "friend", "goto", "typedef", "mix", "min", "max", "abs", "sin", "cos", "pow", "exp", "length",
        "P", "uv", "res", "time", "tex", "orig", "smp"
    ]

    static func sanitizeIdentifier(_ raw: String) -> String {
        var out = ""
        var upperNext = false
        for scalar in raw.unicodeScalars {
            let ch = Character(scalar)
            if scalar.isASCII, ch.isLetter || ch.isNumber || ch == "_" {
                out.append(upperNext && !out.isEmpty ? Character(ch.uppercased()) : ch)
                upperNext = false
            } else {
                upperNext = true
            }
        }
        if out.isEmpty { out = "param" }
        if let first = out.first, first.isNumber { out = "p" + out }
        if out.hasPrefix("__") { out = "p" + out }
        if reservedWords.contains(out) { out = "p_" + out }
        return out
    }

    static func humanize(_ identifier: String) -> String {
        var words: [String] = []
        var current = ""
        for ch in identifier {
            if ch == "_" {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if ch.isUppercase, let last = current.last, last.isLowercase {
                words.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        let joined = words.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

/// Accepts `0.5`, `[1, 0.5, 0]`, `"#FF8800"` or `"0.5"` for a parameter value.
struct FlexibleValue: Codable, Hashable {
    var components: [Float]
    var isColorString = false

    init(_ components: [Float]) { self.components = components }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let f = try? c.decode(Float.self) {
            components = [f]
        } else if let b = try? c.decode(Bool.self) {
            components = [b ? 1 : 0]
        } else if let arr = try? c.decode([Float].self) {
            components = arr
        } else if let s = try? c.decode(String.self) {
            if let rgb = FlexibleValue.parseHex(s) {
                components = rgb
                isColorString = true
            } else if let f = Float(s.trimmingCharacters(in: .whitespaces)) {
                components = [f]
            } else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised value \"\(s)\"")
            }
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected a number, array or hex color")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if components.count == 1 { try c.encode(components[0]) } else { try c.encode(components) }
    }

    static func parseHex(_ raw: String) -> [Float]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() } else if s.lowercased().hasPrefix("0x") { s.removeFirst(2) } else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s.prefix(6), radix: 16) else { return nil }
        return [Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255]
    }
}

// MARK: - Passes

/// One full-screen shader pass. Either references a built-in effect (`effect`) or carries custom
/// Metal code (`code`) that defines a `shade(...)` function. Passes run in order; each pass
/// receives the previous pass's output.
struct ShaderPass: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String?
    var effect: String?
    var code: String?
    var params: [ShaderParam] = []
    var enabled = true
    /// Blend between the pass input (0) and the pass output (1).
    var mix: Float = 1

    init(name: String? = nil, effect: String? = nil, code: String? = nil, params: [ShaderParam] = [], enabled: Bool = true, mix: Float = 1) {
        self.name = name
        self.effect = effect
        self.code = code
        self.params = params
        self.enabled = enabled
        self.mix = mix
        normalize()
    }

    /// Convenience for presets: a built-in effect with some parameter overrides.
    static func builtIn(_ effect: String, _ overrides: [String: [Float]] = [:], mix: Float = 1) -> ShaderPass {
        var pass = ShaderPass(effect: effect, mix: mix)
        for (key, value) in overrides {
            if let i = pass.params.firstIndex(where: { $0.name == key }) {
                pass.params[i].value = value
                pass.params[i].normalize()
            }
        }
        return pass
    }

    var isCustom: Bool { builtInEffect == nil }

    var builtInEffect: BuiltInEffect? {
        guard code == nil || code?.isEmpty == true, let effect else { return nil }
        return BuiltInEffects.find(effect)
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let fx = builtInEffect { return fx.displayName }
        if let effect, !effect.isEmpty { return effect }
        return "Custom shader"
    }

    /// Problems that make this pass impossible to build (compile errors are reported separately).
    var structuralProblem: String? {
        if let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !code.contains("shade") { return "Custom code must define `float4 shade(...)`." }
            return nil
        }
        guard let effect, !effect.isEmpty else { return "Pass has neither `effect` nor `code`." }
        if BuiltInEffects.find(effect) == nil {
            return "Unknown effect \"\(effect)\". Valid effects: \(BuiltInEffects.all.map(\.id).joined(separator: ", "))."
        }
        return nil
    }

    /// Fills in built-in parameter definitions (keeping any values already provided), dedupes names, clamps values.
    mutating func normalize() {
        if !mix.isFinite { mix = 1 }
        mix = Swift.min(Swift.max(mix, 0), 1)
        if let code, code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.code = nil }

        if let fx = builtInEffect {
            effect = fx.id
            let provided = params
            params = fx.params.map { def in
                var p = def
                if let given = provided.first(where: { $0.name.caseInsensitiveCompare(def.name) == .orderedSame }) {
                    p.value = given.value
                    if def.kind == .float {
                        // Let recipes widen a built-in's slider range when they need to.
                        if given.min < def.min { p.min = given.min }
                        if given.max > def.max { p.max = given.max }
                    }
                }
                p.normalize()
                return p
            }
        } else {
            var seen = Set<String>()
            params = params.prefix(32).map { param in
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

    enum CodingKeys: String, CodingKey {
        case name, effect, code, params, enabled, mix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        effect = try c.decodeIfPresent(String.self, forKey: .effect)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mix = try c.decodeIfPresent(Float.self, forKey: .mix) ?? 1
        if let list = try? c.decodeIfPresent([ShaderParam].self, forKey: .params) {
            params = list
        } else if let dict = try? c.decodeIfPresent([String: FlexibleValue].self, forKey: .params) {
            // Shorthand used for built-in effects: { "levels": 4, "color": "#000000" }
            params = dict.keys.sorted().map { key in
                let v = dict[key]!
                return ShaderParam(name: key, kind: v.components.count >= 3 ? .color : .float, value: v.components,
                                   min: Swift.min(0, v.components.first ?? 0), max: Swift.max(1, (v.components.first ?? 0) * 2))
            }
        } else {
            params = []
        }
        normalize()
    }

    func encode(to encoder: Encoder) throws {
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

// MARK: - Recipe

/// A complete look: an ordered stack of passes. This is the JSON format Claude produces and the app imports.
struct ShaderRecipe: Codable, Hashable, Identifiable {
    static let formatIdentifier = "shade.recipe/1"

    var id = UUID()
    var name: String
    var description: String?
    var author: String?
    var passes: [ShaderPass]

    init(id: UUID = UUID(), name: String, description: String? = nil, author: String? = nil, passes: [ShaderPass]) {
        self.id = id
        self.name = name
        self.description = description
        self.author = author
        self.passes = passes
    }

    enum CodingKeys: String, CodingKey {
        case format, id, name, description, author, passes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        passes = try c.decode([ShaderPass].self, forKey: .passes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ShaderRecipe.formatIdentifier, forKey: .format)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encode(passes, forKey: .passes)
    }

    /// Problems that make the recipe unusable before we even try to compile it.
    var structuralProblems: [String] {
        if passes.isEmpty { return [] }
        return passes.enumerated().compactMap { i, pass in
            pass.structuralProblem.map { "Pass \(i + 1) (\(pass.displayName)): \($0)" }
        }
    }

    func jsonData(pretty: Bool = true) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys] : [.withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    var jsonString: String { String(decoding: jsonData(), as: UTF8.self) }

    /// A copy with a fresh identity, e.g. when saving an edited preset.
    func duplicated(named newName: String? = nil) -> ShaderRecipe {
        var copy = self
        copy.id = UUID()
        copy.passes = passes.map { var p = $0; p.id = UUID(); return p }
        if let newName { copy.name = newName }
        return copy
    }

    // MARK: Parsing

    enum ParseError: LocalizedError {
        case noJSON
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .noJSON: return "No shader recipe JSON was found in the text."
            case .invalid(let why): return "The recipe JSON could not be read: \(why)"
            }
        }
    }

    static func decode(_ data: Data) throws -> ShaderRecipe {
        do {
            return try JSONDecoder().decode(ShaderRecipe.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw ParseError.invalid("missing \"\(key.stringValue)\" at \(pathString(ctx.codingPath))")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw ParseError.invalid("\(ctx.debugDescription) at \(pathString(ctx.codingPath))")
        } catch let DecodingError.dataCorrupted(ctx) {
            throw ParseError.invalid("\(ctx.debugDescription) \(pathString(ctx.codingPath))")
        } catch {
            throw ParseError.invalid(error.localizedDescription)
        }
    }

    private static func pathString(_ path: [CodingKey]) -> String {
        let s = path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return s.isEmpty ? "the top level" : s
    }

    /// Finds and decodes a recipe inside free text, e.g. a Claude reply or the clipboard.
    /// Looks at fenced code blocks first, then at the outermost `{ ... }` span.
    static func extract(from text: String) throws -> ShaderRecipe {
        var candidates: [String] = []
        let fence = "```"
        var searchStart = text.startIndex
        while let open = text.range(of: fence, range: searchStart..<text.endIndex) {
            guard let lineEnd = text[open.upperBound...].firstIndex(of: "\n") else { break }
            guard let close = text.range(of: fence, range: text.index(after: lineEnd)..<text.endIndex) else { break }
            candidates.append(String(text[text.index(after: lineEnd)..<close.lowerBound]))
            searchStart = close.upperBound
        }
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            candidates.append(String(text[first...last]))
        }
        candidates.append(text)

        var firstError: Error?
        for candidate in candidates where candidate.contains("passes") {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                return try decode(Data(trimmed.utf8))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? ParseError.noJSON
    }
}
