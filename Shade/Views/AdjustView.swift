import SwiftUI

/// Live editing of the current recipe: sliders/colors per pass, enable/mix, reorder, add built-ins, edit code.
struct AdjustView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingPass: ShaderPass.ID?
    @State private var showSaveAs = false
    @State private var saveName = ""

    var body: some View {
        NavigationStack {
            List {
                if model.recipe.passes.isEmpty {
                    Text("No effects yet. Add one below, or create a look with AI.")
                        .foregroundStyle(.secondary)
                }
                ForEach($model.recipe.passes) { $pass in
                    PassSection(pass: $pass, editCode: { editingPass = pass.id }, move: { move(pass.id, by: $0) },
                                delete: { model.recipe.passes.removeAll { $0.id == pass.id } })
                }

                Section {
                    Menu {
                        ForEach(BuiltInEffects.all) { fx in
                            Button(fx.displayName) { model.recipe.passes.append(ShaderPass(effect: fx.id)) }
                        }
                        Divider()
                        Button("Custom Metal code") {
                            let pass = ShaderPass(name: "Custom", code: AdjustView.customTemplate, params: [.float("amount", 0.5, 0, 1)])
                            model.recipe.passes.append(pass)
                            editingPass = pass.id
                        }
                    } label: {
                        Label("Add effect", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle(model.recipe.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { model.saveCurrent() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                        Button {
                            saveName = model.recipe.name
                            showSaveAs = true
                        } label: { Label("Save as…", systemImage: "plus.square.on.square") }
                        Button {
                            UIPasteboard.general.string = model.recipe.jsonString
                            model.showToast("Recipe JSON copied")
                        } label: { Label("Copy JSON", systemImage: "doc.on.doc") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: Binding(get: { editingPass.map(EditTarget.init) }, set: { editingPass = $0?.id })) { target in
                if let index = model.recipe.passes.firstIndex(where: { $0.id == target.id }) {
                    CodeEditorView(pass: $model.recipe.passes[index])
                }
            }
            .alert("Save as", isPresented: $showSaveAs) {
                TextField("Name", text: $saveName)
                Button("Save") { model.saveCurrent(as: saveName.isEmpty ? model.recipe.name : saveName) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    struct EditTarget: Identifiable { let id: ShaderPass.ID }

    private func move(_ id: ShaderPass.ID, by offset: Int) {
        guard let i = model.recipe.passes.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard model.recipe.passes.indices.contains(j) else { return }
        model.recipe.passes.swapAt(i, j)
    }

    static let customTemplate = """
    float4 shade(float2 uv, float2 res, float time, texture2d<float> tex, texture2d<float> orig, sampler smp, constant ShadeParams& P) {
        float3 c = SRC(uv).rgb;
        // Your effect here. Params are P.<name>; see the help in this editor.
        c = mix(c, float3(luma(c)), P.amount);
        return float4(c, 1.0);
    }
    """
}

private struct PassSection: View {
    @Binding var pass: ShaderPass
    let editCode: () -> Void
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        Section {
            if pass.enabled {
                ForEach($pass.params, id: \.name) { $param in
                    ParamRow(param: $param)
                }
                HStack {
                    Text("Mix").font(.subheadline)
                    Slider(value: $pass.mix, in: 0...1)
                    Text(String(format: "%.0f%%", pass.mix * 100)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                }
            }
        } header: {
            HStack {
                Toggle(isOn: $pass.enabled) {
                    Text(pass.displayName).font(.subheadline.weight(.semibold)).textCase(nil)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Menu {
                    Button(action: editCode) { Label(pass.isCustom ? "Edit code" : "View code", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Button { move(-1) } label: { Label("Move up", systemImage: "arrow.up") }
                    Button { move(1) } label: { Label("Move down", systemImage: "arrow.down") }
                    Button(role: .destructive, action: delete) { Label("Remove", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.body)
                }
            }
        }
    }
}

private struct ParamRow: View {
    @Binding var param: ShaderParam

    var body: some View {
        switch param.kind {
        case .color:
            ColorPicker(param.displayName, selection: $param.value.asColor, supportsOpacity: false)
                .font(.subheadline)
        case .float:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(param.displayName).font(.subheadline)
                    Spacer()
                    Text(Self.format(param.scalar)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $param.scalar, in: param.min...param.max)
            }
        }
    }

    static func format(_ v: Float) -> String {
        abs(v) >= 100 ? String(format: "%.0f", v) : (abs(v) >= 10 ? String(format: "%.1f", v) : String(format: "%.3f", v))
    }
}
