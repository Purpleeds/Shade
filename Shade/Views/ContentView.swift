import PhotosUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    enum ActiveSheet: String, Identifiable {
        case library, adjust, create, settings
        var id: String { rawValue }
    }

    enum CaptureMode { case photo, video }

    @State private var sheet: ActiveSheet?
    @State private var captureMode: CaptureMode = .photo
    @State private var flash = false
    @State private var showErrors = false
    @State private var sourceItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = model.renderer {
                MetalView(renderer: renderer)
                    .ignoresSafeArea()
            }

            if flash {
                Color.white.ignoresSafeArea().transition(.opacity)
            }

            overlayMessage

            VStack(spacing: 10) {
                topBar
                if !model.compileErrors.isEmpty { errorBanner }
                Spacer()
                if let toast = model.toast {
                    Text(toast)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                presetStrip
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.2), value: model.toast)
        }
        .onAppear { model.startCamera() }
        .onChange(of: sourceItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    model.useStillImage(image)
                }
                sourceItem = nil
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .library: LibraryView()
            case .adjust: AdjustView().presentationDetents([.medium, .large])
            case .create: CreateView()
            case .settings: SettingsView()
            }
        }
        .statusBarHidden()
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { sheet = .library } label: {
                HStack(spacing: 6) {
                    Text(model.recipe.name).font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            if model.stillImage != nil {
                Button { model.useCamera() } label: {
                    Label("Camera", systemImage: "camera")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            PhotosPicker(selection: $sourceItem, matching: .images) {
                Image(systemName: "photo")
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Preview on a photo")
            Button { sheet = .settings } label: {
                Image(systemName: "gearshape")
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Settings")
        }
        .foregroundStyle(.white)
        .padding(.top, 8)
    }

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showErrors.toggle() } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(model.compileErrors.count == 1 ? "A pass failed to compile" : "\(model.compileErrors.count) passes failed to compile")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showErrors ? "chevron.up" : "chevron.down")
                }
            }
            if showErrors {
                ScrollView {
                    Text(model.compileErrors.joined(separator: "\n\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                Button("Copy errors") { UIPasteboard.general.string = model.compileErrors.joined(separator: "\n\n") }
                    .font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var overlayMessage: some View {
        switch model.cameraState {
        case .denied where model.stillImage == nil:
            VStack(spacing: 12) {
                Image(systemName: "camera.fill").font(.largeTitle)
                Text("Shade needs camera access").font(.headline)
                Text("Allow it in Settings, or tap the photo button to try looks on a picture.")
                    .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
        case .unavailable:
            Text("This device doesn't support Metal.").foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.store.userRecipes.prefix(8)) + Presets.all) { recipe in
                    Button { model.apply(recipe) } label: {
                        Text(recipe.name)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(recipe.id == model.recipe.id ? AnyShapeStyle(Color.white) : AnyShapeStyle(Material.ultraThinMaterial),
                                        in: Capsule())
                            .foregroundStyle(recipe.id == model.recipe.id ? Color.black : Color.white)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if !model.isRecording {
                HStack(spacing: 18) {
                    modeButton("PHOTO", .photo)
                    modeButton("VIDEO", .video)
                }
            } else if let started = model.recordingStarted {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(started))
                    Text(String(format: "● %02d:%02d", seconds / 60, seconds % 60))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            HStack {
                roundButton("square.stack.3d.up", "Library") { sheet = .library }
                Spacer()
                roundButton("slider.horizontal.3", "Adjust") { sheet = .adjust }
                Spacer()
                shutter
                Spacer()
                roundButton("sparkles", "Create with AI") { sheet = .create }
                Spacer()
                roundButton("arrow.triangle.2.circlepath.camera", "Flip camera") { model.flipCamera() }
            }
        }
        .foregroundStyle(.white)
    }

    private func modeButton(_ title: String, _ mode: CaptureMode) -> some View {
        Button(title) { captureMode = mode }
            .font(.caption.weight(.bold))
            .foregroundStyle(captureMode == mode ? Color.yellow : Color.white.opacity(0.8))
    }

    private var shutter: some View {
        Button {
            switch captureMode {
            case .photo:
                model.capturePhoto()
                withAnimation(.easeOut(duration: 0.05)) { flash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeIn(duration: 0.25)) { flash = false }
                }
            case .video:
                model.toggleRecording()
            }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                if captureMode == .photo {
                    Circle().fill(Color.white).frame(width: 60, height: 60)
                } else if model.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 28, height: 28)
                } else {
                    Circle().fill(Color.red).frame(width: 60, height: 60)
                }
            }
        }
        .accessibilityLabel(captureMode == .photo ? "Take photo" : (model.isRecording ? "Stop recording" : "Record video"))
    }

    private func roundButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }
}
