import Combine
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    enum CameraState { case unknown, running, denied, unavailable }

    @Published var recipe: ShaderRecipe {
        didSet {
            renderer?.setRecipe(recipe)
            persistCurrent()
        }
    }
    @Published private(set) var compileErrors: [String] = []
    @Published private(set) var cameraState: CameraState = .unknown
    @Published private(set) var stillImage: UIImage?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStarted: Date?
    @Published var toast: String?

    let store = RecipeStore()
    let renderer: Renderer?
    let camera = CameraManager()
    private var toastTask: Task<Void, Never>?
    private var storeObserver: AnyCancellable?

    private static let currentKey = "currentRecipe"

    init() {
        renderer = Renderer()
        if let data = UserDefaults.standard.data(forKey: AppModel.currentKey), let saved = try? ShaderRecipe.decode(data) {
            recipe = saved
        } else {
            recipe = Presets.all[1]
        }
        storeObserver = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        guard let renderer else {
            cameraState = .unavailable
            return
        }
        renderer.attach(to: camera)
        renderer.onCompileErrors = { [weak self] errors in self?.compileErrors = errors }
        renderer.setRecipe(recipe)
    }

    // MARK: Camera / source

    func startCamera() {
        guard renderer != nil else { return }
        camera.start { [weak self] granted in
            self?.cameraState = granted ? .running : .denied
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active: camera.resume()
        case .background:
            if isRecording { toggleRecording() }
            camera.stop()
        default: break
        }
    }

    func flipCamera() {
        if stillImage != nil { useCamera() }
        camera.flip()
    }

    func useStillImage(_ image: UIImage) {
        stillImage = image
        renderer?.setStillImage(image)
    }

    func useCamera() {
        stillImage = nil
        renderer?.setStillImage(nil)
    }

    // MARK: Recipes

    func apply(_ newRecipe: ShaderRecipe) {
        recipe = newRecipe
    }

    /// Imports a recipe from free text (a Claude reply, JSON, clipboard). Saves it to the library and applies it.
    @discardableResult
    func importRecipe(fromText text: String) -> String? {
        do {
            let parsed = try ShaderRecipe.extract(from: text)
            if let problem = parsed.structuralProblems.first { return problem }
            let stored = (try? store.save(parsed.duplicated())) ?? parsed
            recipe = stored
            showToast("Imported “\(stored.name)”")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func importRecipe(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            showToast("Couldn't read \(url.lastPathComponent)")
            return
        }
        if let error = importRecipe(fromText: String(decoding: data, as: UTF8.self)) {
            showToast(error)
        }
    }

    /// Saves the current (possibly edited) recipe: overwrites user recipes, copies presets.
    func saveCurrent(as name: String? = nil) {
        var toSave = recipe
        if !store.isUserRecipe(recipe) || name != nil {
            toSave = recipe.duplicated(named: name ?? (store.isUserRecipe(recipe) ? recipe.name : "\(recipe.name) (edited)"))
        }
        do {
            recipe = try store.save(toSave)
            showToast("Saved “\(recipe.name)”")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    private func persistCurrent() {
        UserDefaults.standard.set(recipe.jsonData(pretty: false), forKey: AppModel.currentKey)
    }

    // MARK: Capture

    func capturePhoto() {
        guard let renderer else { return }
        renderer.capturePhoto { [weak self] image in
            guard let image else {
                self?.showToast("Nothing to capture yet")
                return
            }
            Task { [weak self] in
                do {
                    try await PhotoSaver.save(image: image)
                    self?.showToast("Photo saved")
                } catch {
                    self?.showToast(error.localizedDescription)
                }
            }
        }
    }

    func toggleRecording() {
        guard let renderer else { return }
        if isRecording {
            isRecording = false
            recordingStarted = nil
            renderer.stopRecording { [weak self] url in
                guard let url else {
                    self?.showToast("Recording failed")
                    return
                }
                Task { [weak self] in
                    do {
                        try await PhotoSaver.save(videoAt: url)
                        self?.showToast("Video saved")
                    } catch {
                        self?.showToast(error.localizedDescription)
                    }
                }
            }
        } else {
            do {
                try renderer.startRecording()
                isRecording = true
                recordingStarted = Date()
            } catch {
                showToast("Couldn't start recording: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Toasts

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
