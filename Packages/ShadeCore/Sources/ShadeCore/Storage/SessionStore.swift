import Foundation

/// The look currently on screen, including edits that haven't been saved to the library.
public struct ActiveLook: Codable, Equatable, Sendable {
    /// Where the look came from, which decides what "Save" does.
    public enum Origin: Equatable, Sendable {
        case preset(UUID)
        case library(UUID)
        case unsaved
    }

    public var recipe: ShaderRecipe
    public var origin: Origin
    /// True when `recipe` differs from the preset/library recipe it came from.
    public var isModified: Bool

    public init(recipe: ShaderRecipe, origin: Origin, isModified: Bool) {
        self.recipe = recipe
        self.origin = origin
        self.isModified = isModified
    }

    /// Works out the origin and modified flag of a recipe by looking it up in the presets and library.
    public static func resolving(_ recipe: ShaderRecipe, library: RecipeLibrary) -> ActiveLook {
        if let preset = Presets.find(recipe.id) {
            return ActiveLook(recipe: recipe, origin: .preset(preset.id), isModified: !recipe.hasSameContent(as: preset))
        }
        if let stored = library.recipe(id: recipe.id) {
            return ActiveLook(recipe: recipe, origin: .library(stored.id), isModified: !recipe.hasSameContent(as: stored))
        }
        return ActiveLook(recipe: recipe, origin: .unsaved, isModified: true)
    }

    enum CodingKeys: String, CodingKey { case recipe, origin, originID, isModified }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipe = try c.decode(ShaderRecipe.self, forKey: .recipe)
        isModified = try c.decode(Bool.self, forKey: .isModified)
        let kind = try c.decode(String.self, forKey: .origin)
        switch kind {
        case "preset": origin = .preset(try c.decode(UUID.self, forKey: .originID))
        case "library": origin = .library(try c.decode(UUID.self, forKey: .originID))
        case "unsaved": origin = .unsaved
        default:
            throw DecodingError.dataCorruptedError(forKey: .origin, in: c, debugDescription: "unknown origin \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recipe, forKey: .recipe)
        try c.encode(isModified, forKey: .isModified)
        switch origin {
        case .preset(let id):
            try c.encode("preset", forKey: .origin)
            try c.encode(id, forKey: .originID)
        case .library(let id):
            try c.encode("library", forKey: .origin)
            try c.encode(id, forKey: .originID)
        case .unsaved:
            try c.encode("unsaved", forKey: .origin)
        }
    }
}

/// Everything about the session worth restoring after a relaunch. Versioned so future changes can migrate it.
public struct SessionState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var activeLook: ActiveLook?

    public init(activeLook: ActiveLook? = nil) {
        schemaVersion = SessionState.currentSchemaVersion
        self.activeLook = activeLook
    }
}

/// Persists `SessionState` as `state.json` in Application Support (not user-visible, backed up).
///
/// Loading never fails the app: a missing file means a fresh session; an unreadable or newer file is
/// moved aside (`state.unreadable-<timestamp>.json`) so it can be inspected, and a fresh session starts.
public final class SessionStore {
    public let fileURL: URL
    private let fileManager: FileManager
    private let log = Log.storage

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public var exists: Bool { fileManager.fileExists(atPath: fileURL.path) }

    public func load() -> SessionState {
        guard exists else { return SessionState() }
        do {
            let data = try FileIO.read(fileURL, limit: RecipeLimits.maxInputBytes * 2, fileManager: fileManager)
            var state = try JSONDecoder().decode(SessionState.self, from: data)
            guard state.schemaVersion <= SessionState.currentSchemaVersion else {
                throw ShadeError(.storageReadFailed, "Saved session is from a newer version of Shade.",
                                 detail: "schema \(state.schemaVersion)")
            }
            if var look = state.activeLook {
                look.recipe = try RecipeValidator.validate(look.recipe)
                state.activeLook = look
            }
            return state
        } catch {
            quarantine(reason: error)
            return SessionState()
        }
    }

    public func save(_ state: SessionState) throws {
        try FileIO.ensureDirectory(fileURL.deletingLastPathComponent(), fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw ShadeError(.storageWriteFailed, "Shade couldn't save the current look.", detail: String(describing: error))
        }
        try FileIO.writeAtomically(data, to: fileURL)
    }

    private func quarantine(reason: Error) {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent("state.unreadable-\(stamp).json")
        do {
            try fileManager.moveItem(at: fileURL, to: aside)
            log.error("session state unreadable, moved to \(aside.lastPathComponent)", reason)
        } catch {
            log.error("session state unreadable and could not be moved aside", reason)
            try? fileManager.removeItem(at: fileURL)
        }
    }
}
