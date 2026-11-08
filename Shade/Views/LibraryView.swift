import ShadeCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var looks: LookStore
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var importError: ShadeError?

    var body: some View {
        NavigationStack {
            List {
                if !looks.library.isEmpty {
                    Section("My recipes") {
                        ForEach(looks.library) { recipe in
                            row(recipe)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        model.attempt("The recipe couldn't be deleted.") { try looks.delete(recipe) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
                if !looks.libraryProblems.isEmpty {
                    Section {
                        ForEach(looks.libraryProblems) { problem in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(problem.fileName).font(.subheadline.weight(.semibold))
                                Text(problem.error.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Label("Files that couldn't be loaded", systemImage: "exclamationmark.triangle")
                    } footer: {
                        Text("These files are still in Files → On My iPhone → Shade. Fix or delete them there.")
                    }
                }
                Section("Built in") {
                    ForEach(Presets.all) { row($0) }
                }
                Section {
                    Text("Recipes are .shade files in Files → On My iPhone → Shade → Recipes. You can AirDrop or share them, and open .shade files from anywhere to import them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .refreshable { looks.reloadLibrary() }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { pasteImport() } label: { Label("Paste from clipboard", systemImage: "doc.on.clipboard") }
                        Button { showImporter = true } label: { Label("Import file…", systemImage: "folder") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.shadeRecipe, .json, .plainText]) { result in
                switch result {
                case .success(let url):
                    do {
                        let recipe = try looks.importFile(at: url)
                        model.showToast("Imported “\(recipe.name)”")
                        dismiss()
                    } catch {
                        importError = ShadeError.wrap(error, as: .recipeInvalid, "That file couldn't be imported.")
                    }
                case .failure(let error):
                    importError = ShadeError.wrap(error, as: .storageReadFailed, "That file couldn't be opened.")
                }
            }
            .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError?.message ?? "")
            }
        }
    }

    private func row(_ recipe: ShaderRecipe) -> some View {
        Button {
            looks.apply(recipe)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if let desc = recipe.description, !desc.isEmpty {
                        Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(recipe.passes.map(\.displayName).joined(separator: " → "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                if recipe.id == looks.recipe.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .contextMenu {
            ShareLink(item: RecipeFile(recipe: recipe), preview: SharePreview(recipe.name)) {
                Label("Share .shade file", systemImage: "square.and.arrow.up")
            }
            Button {
                model.attempt("The recipe couldn't be copied.") {
                    UIPasteboard.general.string = try RecipeCodec.encodedString(recipe)
                }
            } label: {
                Label("Copy JSON", systemImage: "doc.on.doc")
            }
        }
    }

    private func pasteImport() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importError = ShadeError(.recipeInvalidJSON, "The clipboard is empty.")
            return
        }
        do {
            let recipe = try looks.importText(text)
            model.showToast("Imported “\(recipe.name)”")
            dismiss()
        } catch {
            importError = ShadeError.wrap(error, as: .recipeInvalid, "That text couldn't be imported.")
        }
    }
}
