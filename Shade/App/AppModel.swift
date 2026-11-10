import Combine
import Metal
import ShadeCore
import SwiftUI
import UIKit

/// Composition root and device-session state: wires the camera, renderer, shader compiler and
/// `LookStore` together, and owns capture plus user-facing notices.
@MainActor
final class AppModel: ObservableObject {
    enum CameraState: Equatable {
        case starting
        case running
        case denied
        case unavailable(String)
        case interrupted(String)
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    @Published private(set) var compileErrors: [String] = []
    @Published private(set) var cameraState: CameraState = .starting
    @Published private(set) var stillImage: UIImage?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStarted: Date?
    /// Short confirmations ("Photo saved"). Shown as a toast.
    @Published private(set) var toast: String?
    /// Problems the user should read. Shown as an alert.
    @Published var alert: ShadeError?

    // MARK: Performance settings (persisted)

    /// How many megapixels to process, capture and save.
    @Published var resolution: ProcessingResolution {
        didSet {
            UserDefaults.standard.set(resolution.rawValue, forKey: ProcessingResolution.defaultsKey)
            applyResolution()
        }
    }
    /// Lowers the preview resolution automatically while a look is too heavy to stay smooth.
    @Published var smoothMode: Bool {
        didSet {
            UserDefaults.standard.set(smoothMode, forKey: AppModel.smoothModeKey)
            renderer?.setSmoothMode(smoothMode)
        }
    }
    /// Shows frame rate and resolution over the preview.
    @Published var showStats: Bool {
        didSet {
            UserDefaults.standard.set(showStats, forKey: AppModel.showStatsKey)
            connectStats()
        }
    }
    @Published private(set) var stats: RenderStats?

    static let smoothModeKey = "smoothMode"
    static let showStatsKey = "showStats"

    let looks: LookStore
    let renderer: Renderer?
    let camera = CameraService()
    private var cancellables: Set<AnyCancellable> = []
    private var toastTask: Task<Void, Never>?
    private var isSavingCapture = false

    init() {
        TemporaryFiles.sweep()
        looks = LookStore()
        let defaults = UserDefaults.standard
        resolution = ProcessingResolution(storedValue: defaults.string(forKey: ProcessingResolution.defaultsKey))
        smoothMode = defaults.object(forKey: AppModel.smoothModeKey) as? Bool ?? true
        showStats = defaults.bool(forKey: AppModel.showStatsKey)

        var renderer: Renderer?
        var startupError: ShadeError?
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                renderer = try Renderer(device: device)
            } catch {
                startupError = ShadeError.wrap(error, as: .cameraUnavailable, "This device's GPU couldn't be set up.")
            }
        } else {
            startupError = ShadeError(.cameraUnavailable, "This device doesn't support Metal.")
        }
        self.renderer = renderer

        if !looks.libraryProblems.isEmpty {
            Log.storage.warning("\(looks.libraryProblems.count) library file(s) could not be loaded")
        }
        looks.onStorageError = { [weak self] error in self?.alert = error }

        guard let renderer else {
            cameraState = .unavailable(startupError?.message ?? "Metal is unavailable.")
            return
        }
        renderer.attach(to: camera)
        renderer.onCompileErrors = { [weak self] errors in self?.compileErrors = errors }
        renderer.onGPUFault = { [weak self] error, involvedCustomCode in
            if involvedCustomCode { self?.looks.disableCustomPasses() }
            self?.alert = error
        }
        renderer.onRecordingFailed = { [weak self] error in
            self?.finishRecordingState()
            self?.alert = error
        }
        renderer.onRecordingReachedLimit = { [weak self] url in
            self?.finishRecordingState()
            self?.saveVideo(at: url, note: "Recording reached 10 minutes and was saved")
        }
        camera.onStatus = { [weak self] status in self?.cameraStatusChanged(status) }

        // The renderer follows the active look. @Published emits on willSet, so this receives the new value.
        looks.$look
            .map(\.recipe)
            .removeDuplicates()
            .sink { [weak renderer] recipe in renderer?.setRecipe(recipe) }
            .store(in: &cancellables)

        renderer.setSmoothMode(smoothMode)
        applyResolution()
        connectStats()
    }

    private func applyResolution() {
        renderer?.setResolution(resolution)
        camera.setCaptureTier(resolution.captureTier)
    }

    private func connectStats() {
        if showStats {
            renderer?.onStats = { [weak self] stats in self?.stats = stats }
        } else {
            renderer?.onStats = nil
            stats = nil
        }
    }

    /// The GPU compiler, shared with AI generation so validated shaders are reused.
    var shaderCompiler: ShaderCompiling? { renderer?.compiler }

    // MARK: Lifecycle

    func start() {
        guard renderer != nil else { return }
        camera.start()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            camera.resume()
            looks.reloadLibrary()
        case .background:
            if isRecording { toggleRecording() }
            camera.stop()
            looks.flush()
        default:
            break
        }
    }

    private func cameraStatusChanged(_ status: CameraService.Status) {
        switch status {
        case .idle: break
        case .running: cameraState = .running
        case .denied: cameraState = .denied
        case .unavailable(let message): cameraState = .unavailable(message)
        case .interrupted(let message): cameraState = .interrupted(message)
        }
    }

    // MARK: Source

    func flipCamera() {
        if stillImage != nil { useCamera() }
        camera.flip()
    }

    func useStillImage(_ image: UIImage) {
        do {
            try renderer?.setStillImage(image)
            stillImage = image
        } catch {
            alert = ShadeError.wrap(error, as: .generationInvalidInput, "That photo couldn't be used.")
        }
    }

    func useCamera() {
        try? renderer?.setStillImage(nil) // clearing can't fail
        stillImage = nil
    }

    // MARK: Compare & focus

    /// Hold-to-compare: shows the untouched camera while true.
    func setComparing(_ comparing: Bool) {
        renderer?.setBypass(comparing)
    }

    /// Handles a tap on the preview. Returns the image coordinate used if the look has a focus point.
    @discardableResult
    func focus(atViewPoint point: CGPoint, viewSize: CGSize) -> Bool {
        guard looks.recipe.hasFocusPoint,
              let p = renderer?.imageCoordinate(forViewPoint: point, viewSize: viewSize) else { return false }
        return looks.setFocus(x: Float(p.x), y: Float(p.y))
    }

    // MARK: Opening files

    func open(_ url: URL) {
        do {
            let recipe = try looks.importFile(at: url)
            showToast("Imported “\(recipe.name)”")
        } catch {
            alert = ShadeError.wrap(error, as: .recipeInvalid, "\(url.lastPathComponent) couldn't be imported.")
        }
    }

    // MARK: Capture

    func capturePhoto() {
        guard let renderer else { return }
        renderer.capturePhoto { [weak self] result in
            switch result {
            case .failure(let error):
                self?.alert = error
            case .success(let image):
                Task { [weak self] in
                    do {
                        try await PhotoLibrarySaver.save(image: image)
                        self?.showToast("Photo saved")
                    } catch {
                        self?.alert = ShadeError.wrap(error, as: .captureFailed, "The photo couldn't be saved.")
                    }
                }
            }
        }
    }

    func toggleRecording() {
        guard let renderer, !isSavingCapture else { return }
        if isRecording {
            finishRecordingState()
            isSavingCapture = true
            Task { [weak self] in
                do {
                    let url = try await renderer.stopRecording()
                    self?.saveVideo(at: url, note: "Video saved")
                } catch {
                    self?.alert = ShadeError.wrap(error, as: .captureFailed, "The recording couldn't be saved.")
                }
                self?.isSavingCapture = false
            }
        } else {
            do {
                try renderer.startRecording()
                isRecording = true
                recordingStarted = Date()
            } catch {
                alert = ShadeError.wrap(error, as: .captureFailed, "Recording couldn't start.")
            }
        }
    }

    private func finishRecordingState() {
        isRecording = false
        recordingStarted = nil
    }

    private func saveVideo(at url: URL, note: String) {
        Task { [weak self] in
            do {
                try await PhotoLibrarySaver.save(videoAt: url)
                self?.showToast(note)
            } catch {
                self?.alert = ShadeError.wrap(error, as: .captureFailed, "The video couldn't be saved.")
            }
        }
    }

    // MARK: Notices

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Runs a throwing UI action and turns failures into an alert.
    func attempt(_ fallbackMessage: String, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            alert = ShadeError.wrap(error, as: .storageWriteFailed, fallbackMessage)
        }
    }
}
