import PhotosUI
import SwiftUI

/// The three ways to make a new look from a reference image or video.
struct CreateView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var generator = ShaderGenerator()

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
    @State private var localError: String?
    @State private var showSettings = false

    @AppStorage("claudeModel") private var claudeModel = ClaudeClient.defaultModel
    @AppStorage("claudeEffort") private var claudeEffort = ClaudeClient.defaultEffort

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
                    Section { Text(localError).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("Create a look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        generator.cancel()
                        dismiss()
                    }
                }
            }
            .onChange(of: items) { newItems in loadMedia(newItems) }
            .sheet(isPresented: $showSettings) { SettingsView() }
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
        Task {
            do {
                media = try await ReferenceMedia.load(from: newItems)
                if media.isEmpty { localError = "Couldn't load that selection." }
            } catch {
                localError = "Couldn't load that selection: \(error.localizedDescription)"
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
            if Keychain.get(SettingsView.apiKeyAccount) == nil {
                Button("Add your Claude API key") { showSettings = true }
            }
            if generator.isRunning {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(generator.status).foregroundStyle(.secondary)
                }
                Button("Cancel", role: .destructive) { generator.cancel() }
            } else {
                Button {
                    generate()
                } label: {
                    Label("Generate shader", systemImage: "sparkles").bold()
                }
                .disabled(media.isEmpty && notes.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } footer: {
            Text("Uses \(ClaudeClient.displayName(for: claudeModel)), effort \(claudeEffort). Change in Settings.")
        }

        if let error = generator.errorMessage {
            Section("Problem") {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }

        if let recipe = generator.result {
            resultSection(recipe, explanation: generator.explanation)
        }
    }

    private func generate() {
        localError = nil
        guard let key = Keychain.get(SettingsView.apiKeyAccount), !key.isEmpty else {
            showSettings = true
            return
        }
        guard let device = model.renderer?.device else {
            localError = "Metal isn't available on this device."
            return
        }
        let client = ClaudeClient(apiKey: key, model: claudeModel, effort: claudeEffort)
        generator.generate(media: media, notes: notes, client: client, device: device)
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
                let stored = (try? model.store.save(recipe)) ?? recipe
                model.apply(stored)
                model.useCamera()
                dismiss()
            } label: {
                Label("Use this look", systemImage: "camera.filters").bold()
            }
            Button {
                let stored = (try? model.store.save(recipe)) ?? recipe
                model.apply(stored)
                if let image = media.images.first { model.useStillImage(image) }
                dismiss()
            } label: {
                Label("Preview on the reference", systemImage: "photo")
            }
        }
    }

    // MARK: On-device

    @State private var onDeviceResult: ShaderRecipe?

    @ViewBuilder
    private var onDeviceSection: some View {
        referencePicker(maxCount: 1, filter: .images)
        Section {
            Button {
                guard let image = media.images.first else { return }
                onDeviceResult = StyleAnalyzer.recipe(from: image)
                if onDeviceResult == nil { localError = "Couldn't analyze that image." }
            } label: {
                Label("Match style", systemImage: "wand.and.stars").bold()
            }
            .disabled(media.isEmpty)
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
                guard let text = UIPasteboard.general.string, !text.isEmpty else {
                    localError = "The clipboard is empty. Copy Claude's whole reply first."
                    return
                }
                if let error = model.importRecipe(fromText: text) {
                    localError = error + "\n\nTip: ask Claude to fix it, mentioning this error, then copy its new reply."
                } else {
                    dismiss()
                }
            } label: {
                Label("Paste Claude's reply", systemImage: "doc.on.clipboard").bold()
            }
        }
    }
}
