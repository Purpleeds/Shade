import Foundation

/// Hard limits on recipes. They keep imported files and Claude output from exhausting memory,
/// the GPU (every pass is a full-screen draw per frame) or the shader compiler.
public enum RecipeLimits {
    /// Largest file or text we will try to parse.
    public static let maxInputBytes = 1_000_000
    public static let maxPasses = 16
    public static let maxParamsPerPass = 32
    public static let maxCodeCharacters = 20_000
    public static let maxNameCharacters = 80
    public static let maxDescriptionCharacters = 500
}
