import ShadeCore
import SwiftUI

/// Live editing of the active look: sliders/colors per pass, enable/mix, reorder, add built-ins, edit code.
struct AdjustView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var looks: LookStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingPass: ShaderPass.ID?
    @State private var showSaveAs = false
    @State private var saveName = ""
    @State private var showPicker = false

    private var recipe: Binding<ShaderRecipe> { looks.recipeBinding }

    var body: some View {
        NavigationStack {
            List {
                if looks.look.isModified {
                    Section {
                        HStack {
                            Label("Unsaved changes", systemImage: "pencil.circle").font(.subheadline)
                            Spacer()
                            if looks.canRevert {
                                Button("Revert") { looks.revert() }.font(.subheadline)
                            }
                        }
                    }
                }
                if looks.recipe.passes.isEmpty {
                    Text("No effects yet. Add one below, or create a look with AI.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        HStack {
                            Text("Intensity").font(.subheadline)
                            Slider(value: Binding(get: { looks.intensity }, set: { looks.intensity = $0 }), in: 0...1)
                            Text("\(Int((looks.intensity * 100).rounded()))%")
                                .font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                        }
                        Button { looks.remix() } label: {
                            Label("Remix: nudge every slider a little", systemImage: "wand.and.stars")
                        }
                    } header: {
                        Text("Whole look")
                    } footer: {
                        if looks.recipe.hasFocusPoint {
                            Text("Tip: tap the camera preview to move this look's focus point.")
                        }
                    }
                }
                ForEach(recipe.passes) { $pass in
                    PassSection(pass: $pass, editCode: { editingPass = pass.id }, move: { move(pass.id, by: $0) },
                                delete: { recipe.wrappedValue.passes.removeAll { $0.id == pass.id } },
                                randomize: { looks.randomizePass(pass.id) },
                                reset: { looks.resetPass(pass.id) },
                                duplicate: { looks.duplicatePass(pass.id) })
                }

                Section {
                    Button { showPicker = true } label: {
                        Label("Add effect", systemImage: "plus.circle.fill")
                    }
                    .disabled(looks.recipe.passes.count >= RecipeLimits.maxPasses)
                } footer: {
                    if looks.recipe.passes.count >= RecipeLimits.maxPasses {
                        Text("A look can have up to \(RecipeLimits.maxPasses) effects.")
                    }
                }
            }
            .navigationTitle(looks.recipe.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            model.attempt("The look couldn't be saved.") {
                                let saved = try looks.save()
                                model.showToast("Saved “\(saved.name)”")
                            }
                        } label: { Label("Save", systemImage: "square.and.arrow.down") }
                        Button {
                            saveName = looks.recipe.name
                            showSaveAs = true
                        } label: { Label("Save as…", systemImage: "plus.square.on.square") }
                        Button {
                            model.attempt("The recipe couldn't be copied.") {
                                UIPasteboard.general.string = try RecipeCodec.encodedString(looks.recipe)
                                model.showToast("Recipe JSON copied")
                            }
                        } label: { Label("Copy JSON", systemImage: "doc.on.doc") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: Binding(get: { editingPass.map(EditTarget.init) }, set: { editingPass = $0?.id })) { target in
                if let index = looks.recipe.passes.firstIndex(where: { $0.id == target.id }) {
                    CodeEditorView(pass: recipe.passes[index])
                }
            }
            .sheet(isPresented: $showPicker) {
                EffectPickerView { choice in
                    switch choice {
                    case .builtIn(let fx):
                        add(ShaderPass(effect: fx.id))
                    case .custom:
                        let pass = ShaderPass(name: "Custom", code: AdjustView.customTemplate, params: [.float("amount", 0.5, 0, 1)])
                        add(pass)
                        editingPass = pass.id
                    }
                }
            }
            .alert("Save as", isPresented: $showSaveAs) {
                TextField("Name", text: $saveName)
                Button("Save") {
                    model.attempt("The look couldn't be saved.") {
                        let saved = try looks.saveAsNew(named: saveName.isEmpty ? looks.recipe.name : saveName)
                        model.showToast("Saved “\(saved.name)”")
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    struct EditTarget: Identifiable { let id: ShaderPass.ID }

    private func add(_ pass: ShaderPass) {
        looks.addPass(pass)
    }

    private func move(_ id: ShaderPass.ID, by offset: Int) {
        var passes = looks.recipe.passes
        guard let i = passes.firstIndex(where: { $0.id == id }), passes.indices.contains(i + offset) else { return }
        passes.swapAt(i, i + offset)
        recipe.wrappedValue.passes = passes
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
    let randomize: () -> Void
    let reset: () -> Void
    let duplicate: () -> Void

    private var defaults: [String: [Float]] {
        Dictionary(uniqueKeysWithValues: (pass.builtInEffect?.params ?? []).map { ($0.name, $0.value) })
    }

    var body: some View {
        Section {
            if pass.enabled {
                ForEach($pass.params, id: \.name) { $param in
                    ParamRow(param: $param, defaultValue: defaults[param.name])
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
                if pass.hasFocusPoint {
                    Image(systemName: "scope").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Tap the preview to move the focus point")
                }
                if pass.usesHistory {
                    Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Uses the previous frame")
                }
                Menu {
                    Button(action: randomize) { Label("Randomize", systemImage: "dice") }
                    if pass.builtInEffect != nil {
                        Button(action: reset) { Label("Reset to defaults", systemImage: "arrow.counterclockwise") }
                    }
                    Button(action: duplicate) { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Divider()
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
    /// The built-in default, when known; shows a reset button once the value differs.
    let defaultValue: [Float]?

    private var canReset: Bool {
        guard let defaultValue else { return false }
        return zip(defaultValue, param.value).contains { abs($0 - $1) > 0.0005 }
    }

    private var resetButton: some View {
        Button {
            if let defaultValue { param.value = defaultValue }
        } label: {
            Image(systemName: "arrow.uturn.backward.circle").font(.caption)
        }
        .buttonStyle(.borderless)
        .opacity(canReset ? 1 : 0)
        .disabled(!canReset)
        .accessibilityLabel("Reset \(param.displayName)")
    }

    var body: some View {
        switch param.kind {
        case .color:
            HStack {
                ColorPicker(param.displayName, selection: $param.value.asColor, supportsOpacity: false)
                    .font(.subheadline)
                resetButton
            }
        case .float:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(param.displayName).font(.subheadline)
                    Spacer()
                    Text(Self.format(param.scalar)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    resetButton
                }
                Slider(value: $param.scalar, in: param.min...param.max)
            }
        }
    }

    static func format(_ v: Float) -> String {
        abs(v) >= 100 ? String(format: "%.0f", v) : (abs(v) >= 10 ? String(format: "%.1f", v) : String(format: "%.3f", v))
    }
}
