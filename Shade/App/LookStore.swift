import Foundation
import ShadeCore
import SwiftUI

/// The active look and the recipe library, persisted through ShadeCore.
///
/// Edits change `look` immediately (the renderer follows it) and are written to `state.json` shortly
/// after the last change, not on every slider tick. `flush()` writes immediately (used when the app
/// goes to the background).
@MainActor
final class LookStore: ObservableObject {
    @Published private(set) var look: ActiveLook
    @Published private(set) var library: [ShaderRecipe] = []
    @Published private(set) var libraryProblems: [LibraryFileProblem] = []

    /// Called when a background save fails (surfaced to the user once per failure streak).
    var onStorageError: ((ShadeError) -> Void)?

    private let recipeLibrary: RecipeLibrary
    private let session: SessionStore
    private var saveTask: Task<Void, Never>?
    private var lastSaveFailed = false
    private let log = Log.storage

    static let saveDelay: UInt64 = 400_000_000 // 0.4 s

    init(paths: StoragePaths = .standard(), defaults: UserDefaults = .standard) {
        recipeLibrary = RecipeLibrary(directory: paths.recipesDirectory, inboxDirectory: paths.inboxDirectory)
        session = SessionStore(fileURL: paths.sessionFile)
        let report = recipeLibrary.reload()
        LegacyMigration.migrateActiveLook(defaults: defaults, sessionStore: session, library: recipeLibrary)

        var restored = session.load().activeLook ?? ActiveLook(recipe: Presets.all[1], origin: .preset(Presets.all[1].id), isModified: false)
        if case .library(let id) = restored.origin, !recipeLibrary.contains(id: id) {
            // The file was deleted outside the app (e.g. in the Files app). Keep the look as unsaved work.
            restored.origin = .unsaved
            restored.isModified = true
        }
        look = restored
        library = recipeLibrary.recipes
        libraryProblems = report.problems
    }

    // MARK: Reading

    var recipe: ShaderRecipe { look.recipe }

    /// A binding for editors: every change marks the look as modified and schedules a save.
    var recipeBinding: Binding<ShaderRecipe> {
        Binding(get: { self.look.recipe }, set: { self.edit($0) })
    }

    var canRevert: Bool { look.isModified && sourceRecipe != nil }

    private var sourceRecipe: ShaderRecipe? {
        switch look.origin {
        case .preset(let id): return Presets.find(id)
        case .library(let id): return recipeLibrary.recipe(id: id)
        case .unsaved: return nil
        }
    }

    // MARK: Changing the active look

    func apply(_ recipe: ShaderRecipe) {
        look = ActiveLook.resolving(recipe, library: recipeLibrary)
        scheduleSave()
    }

    func edit(_ recipe: ShaderRecipe) {
        guard recipe != look.recipe else { return }
        look.recipe = recipe
        look.isModified = true
        scheduleSave()
    }

    func revert() {
        guard let source = sourceRecipe else { return }
        apply(source)
    }

    /// Used after a GPU fault: keeps the look but switches off every custom-code pass.
    func disableCustomPasses() {
        var recipe = look.recipe
        for i in recipe.passes.indices where recipe.passes[i].isCustom { recipe.passes[i].enabled = false }
        edit(recipe)
    }

    // MARK: Quick customisation

    /// How strongly the whole look is applied (0 = camera, 1 = full look).
    var intensity: Float {
        get { look.recipe.intensity }
        set {
            var recipe = look.recipe
            recipe.intensity = min(max(newValue, 0), 1)
            edit(recipe)
        }
    }

    /// Moves the focus point of every pass that has one. Returns false if the look has none.
    @discardableResult
    func setFocus(x: Float, y: Float) -> Bool {
        var recipe = look.recipe
        guard recipe.setFocus(x: x, y: y) else { return false }
        edit(recipe)
        return true
    }

    func addPass(_ pass: ShaderPass) {
        guard look.recipe.passes.count < RecipeLimits.maxPasses else { return }
        var recipe = look.recipe
        recipe.passes.append(pass)
        edit(recipe)
    }

    func randomizePass(_ id: ShaderPass.ID) {
        updatePass(id) { pass in
            var rng = SystemRandomNumberGenerator()
            return pass.randomized(using: &rng)
        }
    }

    func resetPass(_ id: ShaderPass.ID) {
        updatePass(id) { $0.resetToDefaults() ?? $0 }
    }

    func duplicatePass(_ id: ShaderPass.ID) {
        guard look.recipe.passes.count < RecipeLimits.maxPasses,
              let i = look.recipe.passes.firstIndex(where: { $0.id == id }) else { return }
        var recipe = look.recipe
        recipe.passes.insert(recipe.passes[i].duplicated(), at: i + 1)
        edit(recipe)
    }

    /// Nudges every slider of the look a little in a random direction.
    func remix(amount: Float = 0.15) {
        var rng = SystemRandomNumberGenerator()
        edit(look.recipe.remixed(amount: amount, using: &rng))
    }

    private func updatePass(_ id: ShaderPass.ID, _ change: (ShaderPass) -> ShaderPass) {
        guard let i = look.recipe.passes.firstIndex(where: { $0.id == id }) else { return }
        var recipe = look.recipe
        recipe.passes[i] = change(recipe.passes[i])
        edit(recipe)
    }

    // MARK: Library

    /// Saves the active look: overwrites its library file, or stores presets/unsaved looks as a new entry.
    @discardableResult
    func save() throws -> ShaderRecipe {
        let saved: ShaderRecipe
        switch look.origin {
        case .library:
            saved = try recipeLibrary.save(look.recipe)
        case .preset:
            saved = try recipeLibrary.add(renamed(look.recipe, to: "\(look.recipe.name) (edited)"))
        case .unsaved:
            saved = try recipeLibrary.add(look.recipe)
        }
        didStore(saved)
        return saved
    }

    @discardableResult
    func saveAsNew(named name: String) throws -> ShaderRecipe {
        let saved = try recipeLibrary.add(renamed(look.recipe, to: name))
        didStore(saved)
        return saved
    }

    /// Adds an outside recipe (Claude, analyzer) to the library and makes it the active look.
    @discardableResult
    func addAndApply(_ recipe: ShaderRecipe) throws -> ShaderRecipe {
        let saved = try recipeLibrary.add(recipe)
        didStore(saved)
        return saved
    }

    /// Imports a recipe from free text (a Claude reply, JSON from the clipboard).
    @discardableResult
    func importText(_ text: String) throws -> ShaderRecipe {
        try addAndApply(RecipeCodec.extract(from: text))
    }

    /// Imports a `.shade`/`.json` file opened from Files, AirDrop or another app.
    @discardableResult
    func importFile(at url: URL) throws -> ShaderRecipe {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= RecipeLimits.maxInputBytes else {
            throw ShadeError(.recipeTooLarge, "\(url.lastPathComponent) is too large to be a recipe.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ShadeError(.storageReadFailed, "\(url.lastPathComponent) couldn't be opened.", detail: String(describing: error))
        }
        return try addAndApply(RecipeCodec.decode(data))
    }

    func delete(_ recipe: ShaderRecipe) throws {
        try recipeLibrary.delete(id: recipe.id)
        library = recipeLibrary.recipes
        if look.origin == .library(recipe.id) {
            look.origin = .unsaved
            look.isModified = true
            scheduleSave()
        }
    }

    /// Re-reads the library (picks up files added through the Files app or Finder).
    func reloadLibrary() {
        let report = recipeLibrary.reload()
        library = recipeLibrary.recipes
        libraryProblems = report.problems
        if case .library(let id) = look.origin, !recipeLibrary.contains(id: id) {
            look.origin = .unsaved
            look.isModified = true
        }
    }

    private func didStore(_ saved: ShaderRecipe) {
        library = recipeLibrary.recipes
        look = ActiveLook(recipe: saved, origin: .library(saved.id), isModified: false)
        scheduleSave()
    }

    private func renamed(_ recipe: ShaderRecipe, to name: String) -> ShaderRecipe {
        var copy = recipe
        copy.name = name
        return copy
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: LookStore.saveDelay)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Writes the session immediately (call when the app is backgrounded).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    private func persist() {
        do {
            try session.save(SessionState(activeLook: look))
            lastSaveFailed = false
        } catch {
            let shade = ShadeError.wrap(error, as: .storageWriteFailed, "Shade couldn't save the current look.")
            log.error("session save failed: \(shade)")
            if !lastSaveFailed { onStorageError?(shade) }
            lastSaveFailed = true
        }
    }
}
