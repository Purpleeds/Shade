import Foundation

/// A complete look: an ordered stack of passes. This is the JSON format Claude produces,
/// the app stores in `.shade` files, and users share.
///
/// Values of this type are not necessarily valid. Anything that comes from outside the app
/// (a file, the clipboard, Claude) goes through `RecipeCodec` + `RecipeValidator` first.
public struct ShaderRecipe: Codable, Hashable, Identifiable, Sendable {
    /// File format identifier written into every recipe. Bump the number only for changes
    /// older app versions cannot read; additive optional fields keep version 1.
    public static let formatIdentifier = "shade.recipe/1"
    public static let formatPrefix = "shade.recipe/"
    public static let currentFormatVersion = 1

    public var id: UUID
    public var name: String
    public var description: String?
    public var author: String?
    public var passes: [ShaderPass]

    public init(id: UUID = UUID(), name: String, description: String? = nil, author: String? = nil, passes: [ShaderPass]) {
        self.id = id
        self.name = name
        self.description = description
        self.author = author
        self.passes = passes
    }

    enum CodingKeys: String, CodingKey {
        case format, id, name, description, author, passes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let format = try c.decodeIfPresent(String.self, forKey: .format) {
            try ShaderRecipe.checkFormat(format, codingPath: c.codingPath + [CodingKeys.format])
        }
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        passes = try c.decode([ShaderPass].self, forKey: .passes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ShaderRecipe.formatIdentifier, forKey: .format)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encode(passes, forKey: .passes)
    }

    /// Thrown inside decoding so `RecipeCodec` can turn it into `.recipeUnsupportedFormat`.
    struct UnsupportedFormat: Error {
        let format: String
    }

    private static func checkFormat(_ format: String, codingPath: [CodingKey]) throws {
        guard format.hasPrefix(formatPrefix), let version = Int(format.dropFirst(formatPrefix.count)) else {
            throw UnsupportedFormat(format: format)
        }
        if version > currentFormatVersion || version < 1 { throw UnsupportedFormat(format: format) }
    }

    /// A copy with a fresh identity, e.g. when saving an edited preset or importing a shared file.
    public func duplicated(named newName: String? = nil) -> ShaderRecipe {
        var copy = self
        copy.id = UUID()
        copy.passes = passes.map { var p = $0; p.id = UUID(); return p }
        if let newName { copy.name = newName }
        return copy
    }

    /// Compares what the recipe *does* (passes, params, name...), ignoring runtime pass ids.
    public func hasSameContent(as other: ShaderRecipe) -> Bool {
        guard let a = try? RecipeCodec.encode(self, pretty: false),
              let b = try? RecipeCodec.encode(other, pretty: false) else { return false }
        return a == b
    }

    public var hasCustomCode: Bool { passes.contains { $0.hasCustomCode } }
}
