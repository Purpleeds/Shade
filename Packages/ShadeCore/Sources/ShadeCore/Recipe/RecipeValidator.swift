import Foundation

/// Enforces recipe invariants at the boundary. After `validate`, the rest of the app can trust:
/// - the name is non-empty, trimmed and bounded; description bounded
/// - 0...maxPasses passes, each either a known built-in effect or custom code that mentions `shade`
/// - custom code and parameter counts within limits; parameter names are valid, unique Metal identifiers
/// - every number is finite and inside its range (done by `normalize`)
public enum RecipeValidator {
    public static func problems(in recipe: ShaderRecipe) -> [String] {
        var problems: [String] = []
        if recipe.passes.count > RecipeLimits.maxPasses {
            problems.append("It has \(recipe.passes.count) passes; the maximum is \(RecipeLimits.maxPasses).")
        }
        for (i, pass) in recipe.passes.enumerated() {
            if let problem = problem(in: pass) {
                problems.append("Pass \(i + 1) (\(pass.displayName)): \(problem)")
            }
        }
        return problems
    }

    public static func problem(in pass: ShaderPass) -> String? {
        if pass.params.count > RecipeLimits.maxParamsPerPass {
            return "it has \(pass.params.count) parameters; the maximum is \(RecipeLimits.maxParamsPerPass)."
        }
        if let code = pass.code, pass.hasCustomCode {
            if code.count > RecipeLimits.maxCodeCharacters {
                return "its code is \(code.count) characters; the maximum is \(RecipeLimits.maxCodeCharacters)."
            }
            if !code.contains("shade") { return "custom code must define `float4 shade(...)`." }
            return nil
        }
        guard let effect = pass.effect, !effect.isEmpty else { return "it has neither `effect` nor `code`." }
        if BuiltInEffects.find(effect) == nil {
            return "unknown effect \"\(effect)\". Valid effects: \(BuiltInEffects.all.map(\.id).joined(separator: ", "))."
        }
        return nil
    }

    /// Returns a normalized copy or throws `.recipeInvalid` listing every problem.
    public static func validate(_ recipe: ShaderRecipe) throws -> ShaderRecipe {
        var r = recipe
        r.name = clean(r.name, limit: RecipeLimits.maxNameCharacters)
        if r.name.isEmpty { r.name = "Untitled" }
        r.description = r.description.map { clean($0, limit: RecipeLimits.maxDescriptionCharacters) }.flatMap { $0.isEmpty ? nil : $0 }
        r.author = r.author.map { clean($0, limit: RecipeLimits.maxNameCharacters) }.flatMap { $0.isEmpty ? nil : $0 }
        r.passes = r.passes.map { var p = $0; p.normalize(); return p }
        let found = problems(in: r)
        guard found.isEmpty else {
            throw ShadeError(.recipeInvalid, "The recipe has problems:\n" + found.joined(separator: "\n"))
        }
        return r
    }

    /// Trims, collapses control characters to spaces and caps length.
    static func clean(_ s: String, limit: Int) -> String {
        let scalars = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) : trimmed
    }
}
