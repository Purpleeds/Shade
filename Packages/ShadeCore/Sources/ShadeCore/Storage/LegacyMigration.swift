import Foundation

/// One-time upgrades from the data layout of Shade 1.0.
///
/// 1.0 kept the on-screen look (with any unsaved edits) as a JSON blob in UserDefaults under
/// `currentRecipe`, rewritten on every slider move. It now lives in `state.json` (see `SessionStore`).
///
/// The migration is safe to run on every launch:
/// - nothing to migrate -> no-op
/// - state.json already holds a look -> the stale key is removed (a previous run crashed before cleanup)
/// - the blob is unreadable -> it is moved to `currentRecipe.unreadable` instead of being retried forever
/// - writing state.json fails -> the key is kept and the migration retries next launch
///
/// Recipe files need no migration: the `.shade` format is unchanged (`shade.recipe/1`).
/// Files 1.0 read from the Documents root are imported into Documents/Recipes by `RecipeLibrary`.
public enum LegacyMigration {
    public static let currentRecipeKey = "currentRecipe"
    public static let unreadableKey = "currentRecipe.unreadable"

    public enum Outcome: Equatable {
        case nothingToMigrate
        case alreadyMigrated
        case migrated(ActiveLook.Origin)
        case unreadable
        case failed(ShadeError)
    }

    @discardableResult
    public static func migrateActiveLook(defaults: UserDefaults, sessionStore: SessionStore, library: RecipeLibrary) -> Outcome {
        let log = Log.migration
        guard let data = defaults.data(forKey: currentRecipeKey) else { return .nothingToMigrate }

        if sessionStore.exists, sessionStore.load().activeLook != nil {
            defaults.removeObject(forKey: currentRecipeKey)
            log.notice("removed legacy currentRecipe; state.json already present")
            return .alreadyMigrated
        }

        let recipe: ShaderRecipe
        do {
            recipe = try RecipeCodec.decode(data)
        } catch {
            defaults.set(data, forKey: unreadableKey)
            defaults.removeObject(forKey: currentRecipeKey)
            log.error("legacy currentRecipe unreadable; kept under \(unreadableKey)", error)
            return .unreadable
        }

        let look = ActiveLook.resolving(recipe, library: library)
        do {
            try sessionStore.save(SessionState(activeLook: look))
        } catch {
            let shade = ShadeError.wrap(error, as: .storageWriteFailed, "Couldn't migrate the current look.")
            log.error("legacy migration failed; will retry next launch: \(shade)")
            return .failed(shade)
        }
        defaults.removeObject(forKey: currentRecipeKey)
        log.notice("migrated legacy currentRecipe to state.json (origin \(look.origin))")
        return .migrated(look.origin)
    }
}
