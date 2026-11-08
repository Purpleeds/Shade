import Foundation

/// The only way recipes enter or leave the app as bytes. Every decode is followed by validation,
/// so callers get either a valid, normalized recipe or a `ShadeError` with a stable code.
public enum RecipeCodec {
    // MARK: Encoding

    /// Pretty output is for files people read and share; compact output is for state and comparisons.
    public static func encode(_ recipe: ShaderRecipe, pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
                                          : [.withoutEscapingSlashes, .sortedKeys]
        do {
            return try encoder.encode(recipe)
        } catch {
            throw ShadeError(.recipeInvalid, "This recipe couldn't be saved because it contains invalid values.",
                             detail: String(describing: error))
        }
    }

    public static func encodedString(_ recipe: ShaderRecipe) throws -> String {
        String(decoding: try encode(recipe), as: UTF8.self)
    }

    // MARK: Decoding

    /// Decodes and validates recipe JSON.
    public static func decode(_ data: Data) throws -> ShaderRecipe {
        guard data.count <= RecipeLimits.maxInputBytes else {
            throw ShadeError(.recipeTooLarge, "That recipe is too large (over \(RecipeLimits.maxInputBytes / 1000) KB).")
        }
        let recipe: ShaderRecipe
        do {
            recipe = try JSONDecoder().decode(ShaderRecipe.self, from: data)
        } catch let unsupported as ShaderRecipe.UnsupportedFormat {
            throw ShadeError(.recipeUnsupportedFormat,
                             "This recipe uses format \"\(unsupported.format)\", which this version of Shade can't read. Update the app and try again.")
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw invalidJSON("missing \"\(key.stringValue)\" at \(path(ctx.codingPath))")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw invalidJSON("wrong type at \(path(ctx.codingPath)): \(ctx.debugDescription)")
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw invalidJSON("missing value at \(path(ctx.codingPath))")
        } catch let DecodingError.dataCorrupted(ctx) {
            if let unsupported = ctx.underlyingError as? ShaderRecipe.UnsupportedFormat {
                throw ShadeError(.recipeUnsupportedFormat,
                                 "This recipe uses format \"\(unsupported.format)\", which this version of Shade can't read.")
            }
            throw invalidJSON(ctx.codingPath.isEmpty ? "the text isn't valid JSON" : "\(ctx.debugDescription) at \(path(ctx.codingPath))")
        } catch {
            throw invalidJSON(String(describing: error))
        }
        return try RecipeValidator.validate(recipe)
    }

    /// Finds and decodes a recipe inside free text (a Claude reply, the clipboard).
    /// Tries fenced code blocks first, then the outermost `{ ... }` span, then the whole text.
    /// If several candidates fail, the error from the most promising one is reported.
    public static func extract(from text: String) throws -> ShaderRecipe {
        guard text.utf8.count <= RecipeLimits.maxInputBytes else {
            throw ShadeError(.recipeTooLarge, "That text is too large to be a recipe.")
        }
        let candidates = candidateJSON(in: text)
        guard !candidates.isEmpty else {
            throw ShadeError(.recipeInvalidJSON, "No shader recipe was found in the text. Copy Claude's whole reply, including the ```json block.")
        }
        var firstError: Error?
        for candidate in candidates {
            do {
                return try decode(Data(candidate.utf8))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError!
    }

    static func candidateJSON(in text: String) -> [String] {
        var candidates: [String] = []
        let fence = "```"
        var searchStart = text.startIndex
        while let open = text.range(of: fence, range: searchStart..<text.endIndex) {
            guard let lineEnd = text[open.upperBound...].firstIndex(of: "\n") else { break }
            let bodyStart = text.index(after: lineEnd)
            guard let close = text.range(of: fence, range: bodyStart..<text.endIndex) else { break }
            candidates.append(String(text[bodyStart..<close.lowerBound]))
            searchStart = close.upperBound
        }
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            candidates.append(String(text[first...last]))
        }
        candidates.append(text)
        var seen = Set<String>()
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("{") && $0.contains("passes") && seen.insert($0).inserted }
    }

    private static func invalidJSON(_ why: String) -> ShadeError {
        ShadeError(.recipeInvalidJSON, "The recipe couldn't be read: \(why).")
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        let s = codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return s.isEmpty ? "the top level" : s
    }
}
