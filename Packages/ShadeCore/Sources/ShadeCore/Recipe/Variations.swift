import Foundation

/// Ways to explore a look without editing every slider: randomize one pass, nudge a whole look,
/// or put a built-in pass back to its defaults. Focus points (`centerX`/`centerY`) are never moved,
/// because the user placed them deliberately.
public extension ShaderPass {
    static let focusParamNames: Set<String> = ["centerX", "centerY"]

    /// Every float takes a random value in its range and every color a random color.
    func randomized<G: RandomNumberGenerator>(using rng: inout G) -> ShaderPass {
        var copy = self
        for i in copy.params.indices where !ShaderPass.focusParamNames.contains(copy.params[i].name) {
            var p = copy.params[i]
            switch p.kind {
            case .float: p.scalar = Float.random(in: p.min...p.max, using: &rng)
            case .color: p.value = (0..<3).map { _ in Float.random(in: 0...1, using: &rng) }
            }
            p.normalize()
            copy.params[i] = p
        }
        return copy
    }

    /// The built-in effect's default values (keeping id, enabled and mix). Nil for custom-code passes.
    func resetToDefaults() -> ShaderPass? {
        guard let fx = builtInEffect else { return nil }
        var copy = self
        copy.params = fx.params
        return copy
    }

    /// A copy with a new identity, for "Duplicate".
    func duplicated() -> ShaderPass {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

public extension ShaderRecipe {
    /// Moves every parameter by up to `amount` (0...1) of its range, in a random direction.
    func remixed<G: RandomNumberGenerator>(amount: Float, using rng: inout G) -> ShaderRecipe {
        let a = Swift.min(Swift.max(amount, 0), 1)
        var copy = self
        for p in copy.passes.indices {
            for i in copy.passes[p].params.indices where !ShaderPass.focusParamNames.contains(copy.passes[p].params[i].name) {
                var param = copy.passes[p].params[i]
                let span = param.max - param.min
                param.value = param.value.map { $0 + Float.random(in: -a...a, using: &rng) * span }
                // Clamp before normalize: a color channel above 1 would be read as a 0-255 color.
                param.value = param.value.map { Swift.min(Swift.max($0, param.min), param.max) }
                param.normalize()
                copy.passes[p].params[i] = param
            }
        }
        return copy
    }
}
