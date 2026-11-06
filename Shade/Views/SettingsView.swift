import SwiftUI

struct SettingsView: View {
    static let apiKeyAccount = "claude-api-key"

    @Environment(\.dismiss) private var dismiss
    @AppStorage("claudeModel") private var claudeModel = ClaudeClient.defaultModel
    @AppStorage("claudeEffort") private var claudeEffort = ClaudeClient.defaultEffort
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasKey {
                        HStack {
                            Label("API key saved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                Keychain.set(nil, for: Self.apiKeyAccount)
                                hasKey = false
                            }
                        }
                    }
                    SecureField(hasKey ? "Replace key (sk-ant-…)" : "sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        hasKey = Keychain.set(trimmed, for: Self.apiKeyAccount)
                        apiKey = ""
                        saved = hasKey
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if saved { Text("Saved to the iPhone Keychain.").font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text("Create a key at console.anthropic.com → API Keys. It's stored only in this phone's Keychain and sent only to api.anthropic.com. Generating a shader typically costs a few cents.")
                }

                Section {
                    Picker("Model", selection: $claudeModel) {
                        ForEach(ClaudeClient.models) { Text($0.name).tag($0.id) }
                    }
                    Picker("Effort", selection: $claudeEffort) {
                        ForEach(ClaudeClient.efforts, id: \.self) { Text($0.capitalized).tag($0) }
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
            .onAppear { hasKey = Keychain.get(Self.apiKeyAccount) != nil }
        }
    }
}
