import Foundation

/// A file that couldn't be loaded or imported, kept so the UI can say *which* file and *why*
/// instead of silently hiding it.
public struct LibraryFileProblem: Equatable, Sendable, Identifiable {
    public var id: String { fileName }
    public let fileName: String
    public let error: ShadeError
}

public struct LibraryLoadReport: Equatable, Sendable {
    public var loadedCount = 0
    /// Names of files moved in from the inbox (Documents root) during this load.
    public var importedFiles: [String] = []
    /// Files whose recipe id clashed with another file and got a new id written back.
    public var reassignedIDs: [String] = []
    public var problems: [LibraryFileProblem] = []
    public init() {}
}

/// The user's recipe library: one `.shade` JSON file per recipe in `Documents/Recipes`.
///
/// The folder is the source of truth (users can see, AirDrop and back it up through the Files app).
/// Invariants this class maintains:
/// - every recipe it returns has passed `RecipeValidator`
/// - recipe ids are unique across the library (clashes from copied files get a new id, written back)
/// - writes are atomic; a failed write leaves the previous file intact
/// - files dropped into the inbox folder (the Documents root) are moved into the library once,
///   and the original is only removed after the copy is safely written
///
/// Not thread-safe: use it from one actor (the app uses it on the main actor).
public final class RecipeLibrary {
    public static let fileExtension = "shade"
    static let readableExtensions: Set<String> = ["shade", "json"]

    public let directory: URL
    public let inboxDirectory: URL?
    private let fileManager: FileManager
    private let log = Log.storage

    public private(set) var recipes: [ShaderRecipe] = []
    public private(set) var lastReport = LibraryLoadReport()
    private var urls: [UUID: URL] = [:]

    public init(directory: URL, inboxDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory
        self.inboxDirectory = inboxDirectory
        self.fileManager = fileManager
    }

    // MARK: Queries

    public func recipe(id: UUID) -> ShaderRecipe? { recipes.first { $0.id == id } }
    public func contains(id: UUID) -> Bool { urls[id] != nil }

    // MARK: Loading

    /// Re-reads the library from disk (after importing the inbox). Never throws: problems are
    /// collected per file in the returned report, so one bad file can't hide the rest.
    @discardableResult
    public func reload() -> LibraryLoadReport {
        var report = LibraryLoadReport()
        do {
            try FileIO.ensureDirectory(directory, fileManager: fileManager)
        } catch {
            let shade = ShadeError.wrap(error, as: .storageWriteFailed, "Shade couldn't open its Recipes folder.")
            report.problems.append(LibraryFileProblem(fileName: directory.lastPathComponent, error: shade))
            lastReport = report
            log.error("library folder unavailable: \(shade)")
            return report
        }

        importInbox(into: &report)

        var loaded: [(recipe: ShaderRecipe, date: Date)] = []
        var newURLs: [UUID: URL] = [:]
        for url in recipeFiles(in: directory) {
            do {
                var recipe = try RecipeCodec.decode(FileIO.read(url, limit: RecipeLimits.maxInputBytes, fileManager: fileManager))
                if newURLs[recipe.id] != nil || Presets.find(recipe.id) != nil {
                    // A copied file (or a saved preset with its fixed id). Give it its own identity on disk,
                    // so the id stays stable across launches.
                    recipe.id = UUID()
                    try FileIO.writeAtomically(RecipeCodec.encode(recipe), to: url)
                    report.reassignedIDs.append(url.lastPathComponent)
                    log.notice("reassigned duplicate recipe id in \(url.lastPathComponent)")
                }
                newURLs[recipe.id] = url
                loaded.append((recipe, FileIO.modificationDate(url)))
            } catch {
                let shade = ShadeError.wrap(error, as: .storageReadFailed, "\(url.lastPathComponent) couldn't be read.")
                report.problems.append(LibraryFileProblem(fileName: url.lastPathComponent, error: shade))
                log.warning("skipped \(url.lastPathComponent): \(shade)")
            }
        }
        recipes = loaded.sorted { $0.date > $1.date }.map(\.recipe)
        urls = newURLs
        report.loadedCount = recipes.count
        lastReport = report
        log.info("library loaded: \(report.loadedCount) recipes, \(report.importedFiles.count) imported, \(report.problems.count) problems")
        return report
    }

    /// Moves recipe files someone dropped into the inbox (e.g. via Finder file sharing) into the library.
    /// `.json` files that aren't recipes are left alone; broken `.shade` files are reported and left in place.
    private func importInbox(into report: inout LibraryLoadReport) {
        guard let inbox = inboxDirectory, inbox.standardizedFileURL != directory.standardizedFileURL else { return }
        for url in recipeFiles(in: inbox) {
            let isShadeFile = url.pathExtension.lowercased() == RecipeLibrary.fileExtension
            let recipe: ShaderRecipe
            do {
                recipe = try RecipeCodec.decode(FileIO.read(url, limit: RecipeLimits.maxInputBytes, fileManager: fileManager))
            } catch {
                if isShadeFile {
                    let shade = ShadeError.wrap(error, as: .storageReadFailed, "\(url.lastPathComponent) couldn't be read.")
                    report.problems.append(LibraryFileProblem(fileName: url.lastPathComponent, error: shade))
                }
                continue
            }
            let destination = uniqueURL(for: recipe.name)
            do {
                try FileIO.writeAtomically(RecipeCodec.encode(recipe), to: destination)
            } catch {
                report.problems.append(LibraryFileProblem(fileName: url.lastPathComponent,
                                                          error: ShadeError.wrap(error, as: .storageWriteFailed, "Couldn't import \(url.lastPathComponent).")))
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                report.importedFiles.append(url.lastPathComponent)
                log.info("imported \(url.lastPathComponent) from inbox")
            } catch {
                // Keep exactly one copy: undo the import so the next launch doesn't import it twice.
                try? fileManager.removeItem(at: destination)
                report.problems.append(LibraryFileProblem(
                    fileName: url.lastPathComponent,
                    error: ShadeError(.storageDeleteFailed, "\(url.lastPathComponent) couldn't be moved into the library.",
                                      detail: String(describing: error))))
            }
        }
    }

    private func recipeFiles(in folder: URL) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { RecipeLibrary.readableExtensions.contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Mutations

    /// Validates and writes a recipe. Overwrites the existing file if the id is already in the library,
    /// otherwise creates a new file. Returns the stored (normalized) recipe.
    @discardableResult
    public func save(_ recipe: ShaderRecipe) throws -> ShaderRecipe {
        var valid = try RecipeValidator.validate(recipe)
        if Presets.find(valid.id) != nil { valid.id = UUID() } // presets are read-only; store a copy
        try FileIO.ensureDirectory(directory, fileManager: fileManager)
        let url = urls[valid.id] ?? uniqueURL(for: valid.name)
        try FileIO.writeAtomically(RecipeCodec.encode(valid), to: url)
        urls[valid.id] = url
        recipes.removeAll { $0.id == valid.id }
        recipes.insert(valid, at: 0)
        log.info("saved recipe \(valid.id) to \(url.lastPathComponent)")
        return valid
    }

    /// Adds a recipe that came from outside (paste, file, Claude) as a new library entry.
    @discardableResult
    public func add(_ recipe: ShaderRecipe) throws -> ShaderRecipe {
        try save(recipe.duplicated())
    }

    public func delete(id: UUID) throws {
        guard let url = urls[id] else {
            throw ShadeError(.recipeNotFound, "That recipe is no longer in your library.")
        }
        do {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        } catch {
            throw ShadeError(.storageDeleteFailed, "The recipe couldn't be deleted.", detail: String(describing: error))
        }
        urls[id] = nil
        recipes.removeAll { $0.id == id }
        log.info("deleted recipe \(id)")
    }

    // MARK: File names

    /// A safe, readable file name for a recipe: letters, digits and dashes, at most 40 characters.
    public static func fileName(for name: String) -> String {
        let mapped = name.unicodeScalars.map { scalar -> Character in
            let ch = Character(scalar)
            return scalar.isASCII && (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        var base = String(mapped)
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "recipe" }
        return String(base.prefix(40)) + "." + fileExtension
    }

    private func uniqueURL(for name: String) -> URL {
        let file = RecipeLibrary.fileName(for: name)
        let base = String(file.dropLast(fileExtensionSuffixLength))
        var url = directory.appendingPathComponent(file)
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(n).\(RecipeLibrary.fileExtension)")
            n += 1
        }
        return url
    }

    private var fileExtensionSuffixLength: Int { RecipeLibrary.fileExtension.count + 1 }
}
