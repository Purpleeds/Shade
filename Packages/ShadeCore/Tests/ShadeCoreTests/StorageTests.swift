import XCTest
@testable import ShadeCore

final class RecipeLibraryTests: XCTestCase {
    var tmp: TempDir!
    var recipesDir: URL { tmp.url.appendingPathComponent("Recipes") }

    override func setUpWithError() throws { tmp = try TempDir() }

    func makeLibrary() -> RecipeLibrary { RecipeLibrary(directory: recipesDir, inboxDirectory: tmp.url) }

    func testSavedRecipesSurviveAReload() throws {
        let library = makeLibrary()
        library.reload()
        let saved = try library.add(Presets.all[2])
        XCTAssertNotEqual(saved.id, Presets.all[2].id, "adding gives a new identity")

        let fresh = makeLibrary()
        let report = fresh.reload()
        XCTAssertEqual(report.loadedCount, 1)
        XCTAssertTrue(try XCTUnwrap(fresh.recipe(id: saved.id)).hasSameContent(as: saved))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recipesDir.appendingPathComponent("Neon-Edges.shade").path))
    }

    func testSavingTwiceOverwritesTheSameFile() throws {
        let library = makeLibrary()
        library.reload()
        var r = try library.add(Presets.all[3])
        r.name = "Renamed"
        try library.save(r)
        let files = try FileManager.default.contentsOfDirectory(atPath: recipesDir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(makeLibrary().reload().loadedCount, 1)
        XCTAssertEqual(library.recipes.first?.name, "Renamed")
    }

    func testSavingAPresetStoresACopy() throws {
        let library = makeLibrary()
        library.reload()
        let stored = try library.save(Presets.all[1])
        XCTAssertNotEqual(stored.id, Presets.all[1].id)
    }

    func testDuplicateIDsFromCopiedFilesGetStableNewIDs() throws {
        _ = try tmp.write(legacyFileJSON, to: "Recipes/a.shade")
        _ = try tmp.write(legacyFileJSON, to: "Recipes/b.shade")
        let first = makeLibrary()
        let report = first.reload()
        XCTAssertEqual(report.loadedCount, 2)
        XCTAssertEqual(report.reassignedIDs.count, 1)
        XCTAssertEqual(Set(first.recipes.map(\.id)).count, 2)

        let second = makeLibrary()
        let again = second.reload()
        XCTAssertTrue(again.reassignedIDs.isEmpty, "the new id was written back, so it is stable")
        XCTAssertEqual(Set(second.recipes.map(\.id)), Set(first.recipes.map(\.id)))
    }

    func testBrokenFilesAreReportedNotHidden() throws {
        _ = try tmp.write(legacyFileJSON, to: "Recipes/good.shade")
        _ = try tmp.write("{ broken", to: "Recipes/bad.shade")
        _ = try tmp.write(#"{"format":"shade.recipe/9","name":"x","passes":[]}"#, to: "Recipes/future.shade")
        let report = makeLibrary().reload()
        XCTAssertEqual(report.loadedCount, 1)
        XCTAssertEqual(Set(report.problems.map(\.fileName)), ["bad.shade", "future.shade"])
        XCTAssertEqual(report.problems.first { $0.fileName == "future.shade" }?.error.code, .recipeUnsupportedFormat)
    }

    func testInboxFilesAreMovedIntoTheLibraryOnce() throws {
        let dropped = try tmp.write(legacyFileJSON, to: "dropped.shade")
        let otherJSON = try tmp.write(#"{"settings": true}"#, to: "notes.json")
        let brokenShade = try tmp.write("garbage", to: "broken.shade")

        let library = makeLibrary()
        let report = library.reload()
        XCTAssertEqual(report.importedFiles, ["dropped.shade"])
        XCTAssertEqual(library.recipes.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.path), "original removed after a successful copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherJSON.path), "unrelated JSON is left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: brokenShade.path), "broken files stay where they are")
        XCTAssertEqual(report.problems.map(\.fileName), ["broken.shade"])

        XCTAssertEqual(makeLibrary().reload().loadedCount, 1, "no duplicate on the next launch")
    }

    func testDelete() throws {
        let library = makeLibrary()
        library.reload()
        let saved = try library.add(Presets.all[4])
        try library.delete(id: saved.id)
        XCTAssertTrue(library.recipes.isEmpty)
        XCTAssertEqual(makeLibrary().reload().loadedCount, 0)
        XCTAssertShadeError(.recipeNotFound) { try library.delete(id: saved.id) }
    }

    func testInvalidRecipesAreNotWritten() throws {
        let library = makeLibrary()
        library.reload()
        let bad = ShaderRecipe(name: "Bad", passes: [ShaderPass(effect: "nope")])
        XCTAssertShadeError(.recipeInvalid) { try library.save(bad) }
        XCTAssertEqual(makeLibrary().reload().loadedCount, 0)
    }

    func testUnwritableLibraryFolderIsReported() throws {
        _ = try tmp.write("I am a file", to: "Recipes")
        let library = makeLibrary()
        let report = library.reload()
        XCTAssertEqual(report.problems.first?.error.code, .storageWriteFailed)
        XCTAssertShadeError(.storageWriteFailed) { try library.add(Presets.all[2]) }
    }

    func testFileNamesAreSafe() {
        XCTAssertEqual(RecipeLibrary.fileName(for: "Neon / Noir: ../../etc"), "Neon-Noir-etc.shade")
        XCTAssertEqual(RecipeLibrary.fileName(for: "日本"), "recipe.shade")
        XCTAssertEqual(RecipeLibrary.fileName(for: String(repeating: "a", count: 100)).count, 46)
    }
}

final class SessionStoreTests: XCTestCase {
    func testRoundTripsTheActiveLook() throws {
        let tmp = try TempDir()
        let store = SessionStore(fileURL: tmp.url.appendingPathComponent("Shade/state.json"))
        XCTAssertNil(store.load().activeLook, "missing file means a fresh session")
        var recipe = Presets.all[5]
        recipe.passes[0].params[0].value = [9]
        let look = ActiveLook(recipe: recipe, origin: .preset(recipe.id), isModified: true)
        try store.save(SessionState(activeLook: look))
        let loaded = try XCTUnwrap(store.load().activeLook)
        XCTAssertEqual(loaded.origin, .preset(recipe.id))
        XCTAssertTrue(loaded.isModified)
        XCTAssertTrue(loaded.recipe.hasSameContent(as: recipe))
    }

    func testCorruptStateIsMovedAsideNotFatal() throws {
        let tmp = try TempDir()
        let file = try tmp.write("{ nope", to: "state.json")
        let store = SessionStore(fileURL: file)
        XCTAssertNil(store.load().activeLook)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        XCTAssertTrue(aside.contains { $0.hasPrefix("state.unreadable-") })
    }

    func testStateFromANewerAppVersionIsNotMisread() throws {
        let tmp = try TempDir()
        let file = try tmp.write(#"{"schemaVersion": 99}"#, to: "state.json")
        XCTAssertNil(SessionStore(fileURL: file).load().activeLook)
    }
}

final class LegacyMigrationTests: XCTestCase {
    var tmp: TempDir!
    var defaults: UserDefaults!
    var suite: String!
    var store: SessionStore!
    var library: RecipeLibrary!

    override func setUpWithError() throws {
        tmp = try TempDir()
        suite = "shade-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = SessionStore(fileURL: tmp.url.appendingPathComponent("state.json"))
        library = RecipeLibrary(directory: tmp.url.appendingPathComponent("Recipes"))
        library.reload()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func legacyBlob(_ recipe: ShaderRecipe) throws -> Data { try RecipeCodec.encode(recipe, pretty: false) }

    func testUnmodifiedPresetMigratesAsPreset() throws {
        defaults.set(try legacyBlob(Presets.all[1]), forKey: LegacyMigration.currentRecipeKey)
        XCTAssertEqual(LegacyMigration.migrateActiveLook(defaults: defaults, sessionStore: store, library: library), .migrated(.preset(Presets.all[1].id)))
        let look = try XCTUnwrap(store.load().activeLook)
        XCTAssertFalse(look.isModified)
        XCTAssertNil(defaults.data(forKey: LegacyMigration.currentRecipeKey), "legacy key removed after success")
        XCTAssertEqual(LegacyMigration.migrateActiveLook(defaults: defaults, sessionStore: store, library: library), .nothingToMigrate)
    }

    func testEditedPresetKeepsItsEdits() throws {
        var edited = Presets.all[1]
        edited.passes[0].params[0].value = [2]
        defaults.set(try legacyBlob(edited), forKey: LegacyMigration.currentRecipeKey)
        LegacyMigration.migrateActiveLook(defaults: defaults, sessionStore: store, library: library)
        let look = try XCTUnwrap(store.load().activeLook)
        XCTAssertTrue(look.isModified)
        XCTAssertEqual(look.recipe.passes[0].params[0].scalar, 2)
    }

    func testLibraryAndUnsavedOrigins() throws {
        let saved = try library.add(Presets.all[3])
        defaults.set(try legacyBlob(saved), forKey: LegacyMigration.currentRecipeKey)
        XCTAssertEqual(LegacyMigration.migrateActiveLook(defaults: defaults, sessionStore: store, library: library), .migrated(.library(saved.id)))

        try FileManager.default.removeItem(at: store.fileURL)
        defaults.set(try legacyBlob(Presets.all[3].duplicated()), forKey: LegacyMigration.currentRecipeKey)
        XCTAssertEqual(LegacyMigration.migrateActiveLook(defaults: defaults, sessionStore: store, library: library), .migrated(.unsaved))
    }

    func testUnreadableBlobIsSetAsideNotRetriedForever() {
        defaults.set(Data("garbage".utf8), forKey: LegacyMigration.currentRecipeKey)
        XCTAssertEqual(LegacyMigration.migrateActiveLook(defaults: defaults, sessionStore: store, library: library), .unreadable)
        XCTAssertNil(defaults.data(forKey: LegacyMigration.currentRecipeKey))
        XCTAssertNotNil(defaults.data(forKey: LegacyMigration.unreadableKey))
    }

    func testLeftoverKeyAfterACompletedMigrationIsCleanedUp() throws {
        try store.save(SessionState(activeLook: ActiveLook(recipe: Presets.all[2], origin: .preset(Presets.all[2].id), isModified: false)))
        defaults.set(try legacyBlob(Presets.all[4]), forKey: LegacyMigration.currentRecipeKey)
        XCTAssertEqual(LegacyMigration.migrateActiveLook(defaults: defaults, sessionStore: store, library: library), .alreadyMigrated)
        XCTAssertEqual(store.load().activeLook?.recipe.id, Presets.all[2].id, "newer state wins")
    }

    func testFailedWriteKeepsTheLegacyDataForNextLaunch() throws {
        let blocked = SessionStore(fileURL: tmp.url.appendingPathComponent("blocker/state.json"))
        _ = try tmp.write("file in the way", to: "blocker")
        defaults.set(try legacyBlob(Presets.all[2]), forKey: LegacyMigration.currentRecipeKey)
        guard case .failed(let error) = LegacyMigration.migrateActiveLook(defaults: defaults, sessionStore: blocked, library: library) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error.code, .storageWriteFailed)
        XCTAssertNotNil(defaults.data(forKey: LegacyMigration.currentRecipeKey))
    }
}
