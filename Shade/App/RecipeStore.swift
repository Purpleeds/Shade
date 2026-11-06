import Foundation

/// User recipes live as `.shade` JSON files in Documents/Recipes (visible in the Files app under "On My iPhone → Shade").
@MainActor
final class RecipeStore: ObservableObject {
    @Published private(set) var userRecipes: [ShaderRecipe] = []
    private var fileURLs: [UUID: URL] = [:]

    let directory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Recipes", isDirectory: true)
    }()

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let docs = directory.deletingLastPathComponent()
        let candidates = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            + ((try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        var loaded: [(ShaderRecipe, Date)] = []
        var urls: [UUID: URL] = [:]
        for url in candidates where ["shade", "json"].contains(url.pathExtension.lowercased()) {
            guard let data = try? Data(contentsOf: url), var recipe = try? ShaderRecipe.decode(data) else { continue }
            if urls[recipe.id] != nil { recipe.id = UUID() } // duplicate ids from copied files
            urls[recipe.id] = url
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            loaded.append((recipe, date))
        }
        userRecipes = loaded.sorted { $0.1 > $1.1 }.map(\.0)
        fileURLs = urls
    }

    func isUserRecipe(_ recipe: ShaderRecipe) -> Bool { fileURLs[recipe.id] != nil }

    /// Saves (or overwrites) a recipe and returns the stored version.
    @discardableResult
    func save(_ recipe: ShaderRecipe) throws -> ShaderRecipe {
        let url = fileURLs[recipe.id] ?? uniqueURL(for: recipe.name)
        try recipe.jsonData().write(to: url, options: .atomic)
        fileURLs[recipe.id] = url
        userRecipes.removeAll { $0.id == recipe.id }
        userRecipes.insert(recipe, at: 0)
        return recipe
    }

    func delete(_ recipe: ShaderRecipe) {
        if let url = fileURLs[recipe.id] { try? FileManager.default.removeItem(at: url) }
        fileURLs[recipe.id] = nil
        userRecipes.removeAll { $0.id == recipe.id }
    }

    /// Writes a temporary `.shade` file for the share sheet.
    func exportFile(for recipe: ShaderRecipe) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(for: recipe.name))
        do {
            try recipe.jsonData().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func fileName(for name: String) -> String {
        let cleaned = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let base = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (base.isEmpty ? "recipe" : String(base.prefix(40))) + ".shade"
    }

    private func uniqueURL(for name: String) -> URL {
        let file = fileName(for: name)
        let base = (file as NSString).deletingPathExtension
        var url = directory.appendingPathComponent(file)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(n).shade")
            n += 1
        }
        return url
    }
}
