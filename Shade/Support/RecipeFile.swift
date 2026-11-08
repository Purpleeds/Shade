import CoreTransferable
import Foundation
import ShadeCore
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations), extension `.shade`.
    static let shadeRecipe = UTType(exportedAs: "com.shadeapp.recipe")
}

/// A recipe as a shareable `.shade` file. The file is only written when the user actually shares,
/// into a per-share temp folder that `TemporaryFiles.sweep` cleans up later.
struct RecipeFile: Transferable {
    let recipe: ShaderRecipe

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .shadeRecipe) { file in
            let folder = TemporaryFiles.url(prefix: "share-", extension: "d")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(RecipeLibrary.fileName(for: file.recipe.name))
            try RecipeCodec.encode(file.recipe).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
