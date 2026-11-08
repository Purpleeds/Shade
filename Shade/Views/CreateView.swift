import PhotosUI
import ShadeCore
import SwiftUI

/// The three ways to make a new look from a reference image or video.
struct CreateView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var looks: LookStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var generation = GenerationController()

    enum Method: String, CaseIterable, Identifiable {
        case claude = "Claude"
        case onDevice = "On-device"
        case chat = "Claude chat"
        var id: String { rawValue }
    }

    @State private var method: Method = .claude
    @State private var items: [PhotosPickerItem] = []
    @State private var media = ReferenceMedia()
    @State private var loadingMedia = false
    @State private var notes = ""
    @State private var localError: ShadeError?
    @State private var showSettings = false
    @State private var onDeviceResult: ShaderRecipe?
    @State private var hasAPIKey = KeychainSecretStore.claudeAPIKey.hasValue

    @AppStorage(GenerationSettings.modelDefaultsKey) private var claudeModel = GenerationSettings.defaultModel
    @AppStorage(GenerationSettings.effortDefaultsKey) private var claudeEffort = GenerationSettings.defaultEffort

    private var settings: GenerationSettings { GenerationSettings(model: claudeModel, effort: claudeEffort) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: $method) {
                        ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(methodFooter)
                }

                switch method {
                case .claude: claudeSection
                case .onDevice: onDeviceSection
                case .chat: chatSection
                }

                if let localError {
                    Section { Text(localError.message).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("Create a look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        generation.cancel()
                        dismiss()
                    }
                }
            }
            .onChange(of: items) { newItems in loadMedia(newItems) }
            .sheet(isPresented: $showSettings, onDismiss: { hasAPIKey = KeychainSecretStore.claudeAPIKey.hasValue }) { SettingsView() }
            .onDisappear { generation.cancel() }
        }
    }

    private var methodFooter: String {
        switch method {
        case .claude: return "Claude looks at your image or video, writes a shader recipe, and the app compiles it on your GPU. Compile errors are sent back to Claude to fix automatically. Needs a Claude API key."
        case .onDevice: return "Measures the image's palette, contrast, saturation, grain and vignette and builds a look from built-in effects. Works offline, no key needed."
        case .chat: return "No API key? Copy the prompt, paste it into claude.ai with your image or video, then paste Claude's reply back here."
        }
    }

    // MARK: Reference picker

    private func referencePicker(maxCount: Int, filter: PHPickerFilter) -> some View {
        Section("Reference") {
            PhotosPicker(selection: $items, maxSelectionCount: maxCount, matching: filter) {
                Label(media.isEmpty ? "Choose image or video" : "Change selection", systemImage: "photo.on.rectangle")
            }
            if loadingMedia {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            } else if !media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(media.images.indices, id: \.self) { i in
                            Image(uiImage: media.images[i])
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if media.videoFrameCount > 0 {
                    Text("\(media.videoFrameCount) frames taken from the video").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadMedia(_ newItems: [PhotosPickerItem]) {
        guard !newItems.isEmpty else { return }
        loadingMedia = true
        localError = nil
        onDeviceResult = nil
        Task {
            do {
                media = try await ReferenceMedia.load(from: newItems)
            } catch {
                media = ReferenceMedia()
                localError = ShadeError.wrap(error, as: .generationInvalidInput, "Couldn't load that selection.")
            }
            loadingMedia = false
        }
    }

    // MARK: Claude (API)

    @ViewBuilder
    private var claudeSection: some View {
        referencePicker(maxCount: 4, filter: .any(of: [.images, .videos]))

        Section("Notes for Claude (optional)") {
            TextField("e.g. keep skin tones natural, make it animate", text: $notes, axis: .vertical)
                .lineLimit(2...5)
        }

        Section {
            if !hasAPIKey {
                Button("Add your Claude API key") { showSettings = true }
            }
            if generation.isRunning {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(generation.status).foregroundStyle(.secondary)
                }
                Button("Cancel", role: .destructive) { generation.cancel() }
            } else {
                Button {
                    generate()
                } label: {
                    Label("Generate shader", systemImage: "sparkles").bold()
                }
                .disabled(loadingMedia || (media.isEmpty && notes.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        } footer: {
            Text("Uses \(settings.model.name), effort \(settings.effort). Change in Settings.")
        }

        if let error = generation.error {
            Section("Problem") {
                Text(error.message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                if error.code == .claudeMissingKey || error.code == .claudeUnauthorized {
                    Button("Open Settings") { showSettings = true }
                }
            }
        }

        if let result = generation.result {
            resultSection(result.recipe, explanation: result.explanation)
        }
    }

    private func generate() {
        localError = nil
        guard let compiler = model.shaderCompiler else {
            localError = ShadeError(.cameraUnavailable, "Metal isn't available on this device.")
            return
        }
        generation.generate(media: media, notes: notes, settings: settings, compiler: compiler)
    }

    private func resultSection(_ recipe: ShaderRecipe, explanation: String?) -> some View {
        Section("Result") {
            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.name).font(.headline)
                if let explanation { Text(explanation).font(.callout) }
                Text(recipe.passes.map(\.displayName).joined(separator: " → "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                use(recipe, previewOnReference: false)
            } label: {
                Label("Use this look", systemImage: "camera.filters").bold()
            }
            if !media.isEmpty {
                Button {
                    use(recipe, previewOnReference: true)
                } label: {
                    Label("Preview on the reference", systemImage: "photo")
                }
            }
        }
    }

    /// Saves the result to the library and applies it. If saving fails the look is still applied
    /// (as unsaved work) and the user is told why.
    private func use(_ recipe: ShaderRecipe, previewOnReference: Bool) {
        do {
            try looks.addAndApply(recipe)
        } catch {
            looks.apply(recipe)
            model.alert = ShadeError.wrap(error, as: .storageWriteFailed, "The look is applied but couldn't be saved to your library.")
        }
        if previewOnReference, let image = media.images.first {
            model.useStillImage(image)
        } else {
            model.useCamera()
        }
        dismiss()
    }

    // MARK: On-device

    @ViewBuilder
    private var onDeviceSection: some View {
        referencePicker(maxCount: 1, filter: .images)
        Section {
            Button {
                guard let image = media.images.first else { return }
                do {
                    onDeviceResult = try StyleAnalyzer.recipe(from: ImageUtils.analysisBitmap(image))
                    localError = nil
                } catch {
                    localError = ShadeError.wrap(error, as: .generationInvalidInput, "Couldn't analyze that image.")
                }
            } label: {
                Label("Match style", systemImage: "wand.and.stars").bold()
            }
            .disabled(media.isEmpty || loadingMedia)
        }
        if let recipe = onDeviceResult {
            resultSection(recipe, explanation: "Built from the image's colors and tone. Fine-tune it with Adjust.")
        }
    }

    // MARK: Claude chat (manual)

    @ViewBuilder
    private var chatSection: some View {
        Section("1. Copy the prompt") {
            Button {
                UIPasteboard.general.string = RecipeSpec.chatPrompt
                model.showToast("Prompt copied")
            } label: {
                Label("Copy prompt for Claude", systemImage: "doc.on.doc")
            }
            if let url = URL(string: "https://claude.ai/new") {
                Link(destination: url) { Label("Open claude.ai", systemImage: "safari") }
            }
        }
        Section("2. In Claude") {
            Text("Start a new chat, attach your image or video, paste the prompt and send it.")
                .font(.callout)
        }
        Section("3. Bring the result back") {
            Button {
                pasteReply()
            } label: {
                Label("Paste Claude's reply", systemImage: "doc.on.clipboard").bold()
            }
        }
    }

    private func pasteReply() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            localError = ShadeError(.recipeInvalidJSON, "The clipboard is empty. Copy Claude's whole reply first.")
            return
        }
        do {
            let recipe = try looks.importText(text)
            model.showToast("Imported “\(recipe.name)”")
            dismiss()
        } catch {
            let shade = ShadeError.wrap(error, as: .recipeInvalid, "That reply couldn't be imported.")
            localError = ShadeError(shade.code, shade.message + "\n\nTip: tell Claude about this error and copy its corrected reply.")
        }
    }
}
