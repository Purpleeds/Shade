import SwiftUI

/// Edits a pass's Metal code and parameter definitions. Built-in passes are shown read-only until copied.
struct CodeEditorView: View {
    @Binding var pass: ShaderPass
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var paramsJSON = ""
    @State private var paramsError: String?
    @State private var tab = 0

    private var isBuiltIn: Bool { pass.builtInEffect != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Code").tag(0)
                    Text("Params").tag(1)
                    Text("Help").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                switch tab {
                case 0: editor($code)
                case 1:
                    VStack(alignment: .leading) {
                        editor($paramsJSON)
                        if let paramsError {
                            Text(paramsError).font(.caption).foregroundStyle(.red).padding(.horizontal)
                        }
                    }
                default:
                    ScrollView {
                        Text(Self.help)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                }

                if !model.compileErrors.isEmpty {
                    ScrollView {
                        Text(model.compileErrors.joined(separator: "\n\n"))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.yellow)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxHeight: 160)
                    .background(Color.black.opacity(0.4))
                }
            }
            .navigationTitle(pass.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if isBuiltIn {
                        Button("Make editable") { makeEditable() }
                    } else {
                        Button("Apply") { apply() }.bold()
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(.footnote, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .disabled(isBuiltIn)
            .padding(.horizontal, 8)
    }

    private func load() {
        code = ShaderSource.userCode(for: pass) ?? AdjustView.customTemplate
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        paramsJSON = (try? encoder.encode(pass.params)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    private func makeEditable() {
        var copy = pass
        copy.code = ShaderSource.userCode(for: pass)
        copy.name = "\(pass.displayName) (custom)"
        copy.effect = nil
        copy.normalize()
        pass = copy
        load()
    }

    private func apply() {
        do {
            let params = try JSONDecoder().decode([ShaderParam].self, from: Data(paramsJSON.utf8))
            paramsError = nil
            var copy = pass
            copy.code = code
            copy.params = params
            copy.normalize()
            pass = copy
            load()
        } catch {
            paramsError = "Params JSON is invalid: \(error.localizedDescription)"
        }
    }

    static let help = """
    A pass is one function:

    \(ShaderSource.signature)

    uv     0..1, origin top-left
    res    frame size in pixels
    time   seconds (for animation)
    tex    previous pass output
    orig   untouched camera frame

    SRC(p)  sample tex at p
    ORIG(p) sample orig at p
    P.name  your params (colors: float3(P.c))

    Helpers:
    luma(rgb) hash21(p) hash22(p) noise2(p) fbm(p)
    rgb2hsv(c) hsv2rgb(c) gradient5(t,c0..c4)
    sobel(tex, smp, uv, float2 step)  PI  TAU

    Params tab: a JSON array, e.g.
    [{"name":"amount","type":"float","value":0.5,"min":0,"max":1},
     {"name":"tint","type":"color","value":[1,0.5,0.2]}]

    Errors show as shade:<line>:<col>.
    """
}
