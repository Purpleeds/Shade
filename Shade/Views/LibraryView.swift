import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                if !model.store.userRecipes.isEmpty {
                    Section("My recipes") {
                        ForEach(model.store.userRecipes) { recipe in
                            row(recipe)
                                .swipeActions {
                                    Button(role: .destructive) { model.store.delete(recipe) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
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
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes) { result in
                if case .success(let url) = result {
                    model.importRecipe(from: url)
                    dismiss()
                }
            }
            .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    static var importTypes: [UTType] {
        var types: [UTType] = [.json, .plainText]
        if let shade = UTType("com.shadeapp.recipe") { types.insert(shade, at: 0) }
        return types
    }

    private func row(_ recipe: ShaderRecipe) -> some View {
        Button {
            model.apply(recipe)
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
                if recipe.id == model.recipe.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .contextMenu {
            if let url = model.store.exportFile(for: recipe) {
                ShareLink(item: url) { Label("Share .shade file", systemImage: "square.and.arrow.up") }
            }
            Button {
                UIPasteboard.general.string = recipe.jsonString
            } label: {
                Label("Copy JSON", systemImage: "doc.on.doc")
            }
        }
    }

    private func pasteImport() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importError = "The clipboard is empty."
            return
        }
        if let error = model.importRecipe(fromText: text) {
            importError = error
        } else {
            dismiss()
        }
    }
}
