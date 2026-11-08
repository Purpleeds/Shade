import ShadeCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(GenerationSettings.modelDefaultsKey) private var claudeModel = GenerationSettings.defaultModel
    @AppStorage(GenerationSettings.effortDefaultsKey) private var claudeEffort = GenerationSettings.defaultEffort
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var message: String?
    @State private var error: ShadeError?

    private let keyStore = KeychainSecretStore.claudeAPIKey

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasKey {
                        HStack {
                            Label("API key saved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Spacer()
                            Button("Remove", role: .destructive) { removeKey() }
                        }
                    }
                    SecureField(hasKey ? "Replace key (sk-ant-…)" : "sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                    Button("Save key") { saveKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if let error { Text(error.message).font(.caption).foregroundStyle(.red) }
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text("Create a key at console.anthropic.com → API Keys. It's stored only in this iPhone's Keychain (not synced or backed up to other devices) and sent only to api.anthropic.com. Generating a shader typically costs a few cents.")
                }

                Section {
                    Picker("Model", selection: $claudeModel) {
                        ForEach(GenerationSettings.models) { Text($0.name).tag($0.id) }
                    }
                    Picker("Effort", selection: $claudeEffort) {
                        ForEach(GenerationSettings.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                } header: {
                    Text("Shader generation")
                } footer: {
                    Text("Higher effort thinks longer: better shaders, slower and pricier. High is a good balance.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    LabeledContent("Built-in effects", value: "\(BuiltInEffects.all.count)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: refresh)
        }
    }

    private func refresh() {
        do {
            hasKey = try keyStore.read() != nil
        } catch {
            hasKey = false
            self.error = ShadeError.wrap(error, as: .storageReadFailed, "Couldn't read the saved key.")
        }
        // Repair settings that no longer exist (e.g. a removed model) so the pickers show a real choice.
        let valid = GenerationSettings(model: claudeModel, effort: claudeEffort)
        if valid.model.id != claudeModel { claudeModel = valid.model.id }
        if valid.effort != claudeEffort { claudeEffort = valid.effort }
    }

    private func saveKey() {
        do {
            try keyStore.save(apiKey)
            apiKey = ""
            hasKey = true
            error = nil
            message = "Saved to the iPhone Keychain."
        } catch {
            self.error = ShadeError.wrap(error, as: .storageWriteFailed, "Couldn't save the key.")
            message = nil
        }
    }

    private func removeKey() {
        do {
            try keyStore.delete()
            hasKey = false
            message = "Key removed."
            error = nil
        } catch {
            self.error = ShadeError.wrap(error, as: .storageDeleteFailed, "Couldn't remove the key.")
        }
    }
}
