import ShadeCore
import SwiftUI

/// Browse every built-in effect by category, with descriptions and search.
struct EffectPickerView: View {
    enum Choice {
        case builtIn(BuiltInEffect)
        case custom
    }

    let onPick: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private func matches(_ fx: BuiltInEffect) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return fx.displayName.localizedCaseInsensitiveContains(q) || fx.summary.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(EffectCategory.allCases, id: \.self) { category in
                    let effects = BuiltInEffects.inCategory(category).filter(matches)
                    if !effects.isEmpty {
                        Section(category.displayName) {
                            ForEach(effects) { fx in
                                Button {
                                    onPick(.builtIn(fx))
                                    dismiss()
                                } label: {
                                    row(fx)
                                }
                            }
                        }
                    }
                }
                Section("Write your own") {
                    Button {
                        onPick(.custom)
                        dismiss()
                    } label: {
                        Label("Custom Metal code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search effects")
            .navigationTitle("Add effect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func row(_ fx: BuiltInEffect) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(fx.displayName).font(.body.weight(.semibold)).foregroundStyle(.primary)
                if fx.hasFocusPoint {
                    Image(systemName: "scope").font(.caption).foregroundStyle(.secondary)
                }
                if fx.usesHistory {
                    Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(fx.summary).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
