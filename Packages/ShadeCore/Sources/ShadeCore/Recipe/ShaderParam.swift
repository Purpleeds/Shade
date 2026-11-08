import Foundation

// MARK: - Parameters

/// A tweakable value exposed by a shader pass. Floats become sliders, colors become color pickers.
/// Inside Metal code every parameter is available as `P.<name>` (`float` or `packed_float3`).
public struct ShaderParam: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case float
        case color
    }

    public var name: String
    public var kind: Kind
    /// One component for `.float`, three (r, g, b in 0...1) for `.color`.
    public var value: [Float]
    public var min: Float
    public var max: Float
    public var label: String?

    public init(name: String, kind: Kind, value: [Float], min: Float = 0, max: Float = 1, label: String? = nil) {
        self.name = name
        self.kind = kind
        self.value = value
        self.min = min
        self.max = max
        self.label = label
        normalize()
    }

    public static func float(_ name: String, _ value: Float, _ min: Float, _ max: Float, label: String? = nil) -> ShaderParam {
        ShaderParam(name: name, kind: .float, value: [value], min: min, max: max, label: label)
    }

    public static func color(_ name: String, _ r: Float, _ g: Float, _ b: Float, label: String? = nil) -> ShaderParam {
        ShaderParam(name: name, kind: .color, value: [r, g, b], min: 0, max: 1, label: label)
    }

    public var componentCount: Int { kind == .color ? 3 : 1 }

    public var scalar: Float {
        get { value.first ?? 0 }
        set { value = [newValue] }
    }

    public var displayName: String {
        if let label, !label.isEmpty { return label }
        return ShaderParam.humanize(name)
    }

    /// Makes the parameter safe to feed into Metal and SwiftUI (valid identifier, sane range, right arity).
    public mutating func normalize() {
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

    public static let reservedWords: Set<String> = [
        "float", "half", "int", "uint", "bool", "char", "short", "long", "double", "void", "true", "false",
        "if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case", "default",
        "struct", "class", "union", "enum", "const", "constant", "device", "thread", "threadgroup",
        "static", "inline", "kernel", "vertex", "fragment", "sampler", "texture", "using", "namespace",
        "template", "typename", "this", "new", "delete", "auto", "register", "volatile", "extern",
        "signed", "unsigned", "sizeof", "operator", "private", "public", "protected", "virtual",
        "friend", "goto", "typedef", "mix", "min", "max", "abs", "sin", "cos", "pow", "exp", "length",
        "P", "uv", "res", "time", "tex", "orig", "smp"
    ]

    public static func sanitizeIdentifier(_ raw: String) -> String {
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

    public static func humanize(_ identifier: String) -> String {
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
public struct FlexibleValue: Codable, Hashable, Sendable {
    public var components: [Float]
    public var isColorString = false

    public init(_ components: [Float]) { self.components = components }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if components.count == 1 { try c.encode(components[0]) } else { try c.encode(components) }
    }

    public static func parseHex(_ raw: String) -> [Float]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() } else if s.lowercased().hasPrefix("0x") { s.removeFirst(2) } else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s.prefix(6), radix: 16) else { return nil }
        return [Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255]
    }
}

