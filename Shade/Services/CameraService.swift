import AVFoundation
import ShadeCore

/// Owns the capture session and delivers portrait BGRA frames on a background queue.
///
/// Reports its state instead of failing silently: permission denied, no usable camera, interrupted
/// (phone call, another app using the camera, Split View) and runtime errors, which it recovers from
/// by restarting the session when that can help.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Status: Equatable {
        case idle
        case running
        case denied
        case unavailable(String)
        case interrupted(String)
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "shade.camera", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var position: AVCaptureDevice.Position = .back
    private var tier: CaptureTier = ProcessingResolution.defaultValue.captureTier
    private var restartAttempts = 0
    private let log = Log.camera

    /// Called on the camera queue for every frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main thread when the status changes.
    var onStatus: ((Status) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(runtimeError(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        center.addObserver(self, selector: #selector(interrupted(_:)), name: .AVCaptureSessionWasInterrupted, object: session)
        center.addObserver(self, selector: #selector(interruptionEnded(_:)), name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Control

    /// Asks for permission if needed, then starts the session.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.startSession() } else { self.report(.denied) }
            }
        default:
            report(.denied)
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.report(.idle)
        }
    }

    func resume() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        startSession()
    }

    /// Picks the camera stream size. Reconfigures a running session; takes effect on start otherwise.
    func setCaptureTier(_ newTier: CaptureTier) {
        queue.async {
            guard newTier != self.tier else { return }
            self.tier = newTier
            guard self.configured else { return }
            do {
                try self.configure()
            } catch {
                self.fail(error)
            }
        }
    }

    func flip() {
        queue.async {
            self.position = self.position == .back ? .front : .back
            do {
                try self.configure()
            } catch {
                self.fail(error)
            }
        }
    }

    private func startSession() {
        queue.async {
            do {
                if !self.configured { try self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                if self.session.isRunning {
                    self.restartAttempts = 0
                    self.report(.running)
                }
            } catch {
                self.fail(error)
            }
        }
    }

    // MARK: Configuration (camera queue only)

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Ask for the chosen size, falling back to smaller streams when a camera (e.g. the front one) can't do it.
        let wanted: [AVCaptureSession.Preset]
        switch tier {
        case .hd720: wanted = [.hd1280x720, .high]
        case .hd1080: wanted = [.hd1920x1080, .hd1280x720, .high]
        case .uhd4K: wanted = [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
        }

        // Use a preset every camera supports while swapping inputs, so a 4K session can switch to a front camera.
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        for input in session.inputs { session.removeInput(input) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video) else {
            throw ShadeError(.cameraUnavailable, "This device has no camera Shade can use.")
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw ShadeError(.cameraUnavailable, "The camera couldn't be opened.", detail: String(describing: error))
        }
        guard session.canAddInput(input) else {
            throw ShadeError(.cameraUnavailable, "The camera is busy.", detail: "canAddInput false")
        }
        session.addInput(input)
        session.sessionPreset = wanted.first(where: session.canSetSessionPreset) ?? .high

        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                throw ShadeError(.cameraUnavailable, "The camera couldn't be set up.", detail: "canAddOutput false")
            }
            session.addOutput(output)
        }

        if let connection = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = (position == .front)
            }
        }
        configured = true
        log.info("configured \(position == .front ? "front" : "back") camera, preset \(session.sessionPreset.rawValue)")
    }

    // MARK: Notifications

    @objc private func runtimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
        log.error("capture session runtime error: \(String(describing: error))")
        queue.async {
            // Media services resets are recoverable by restarting; give up after a few tries to avoid a loop.
            guard self.restartAttempts < 3 else {
                self.report(.unavailable("The camera stopped working. Close and reopen Shade."))
                return
            }
            self.restartAttempts += 1
            if error?.code == .mediaServicesWereReset { self.configured = false }
            self.startSession()
        }
    }

    @objc private func interrupted(_ note: Notification) {
        let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
        let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
        let message: String
        switch reason {
        case .videoDeviceInUseByAnotherClient: message = "Another app is using the camera."
        case .videoDeviceNotAvailableWithMultipleForegroundApps: message = "The camera is paused while other apps share the screen."
        case .videoDeviceNotAvailableDueToSystemPressure: message = "The camera paused because the iPhone is too hot."
        default: message = "The camera is paused."
        }
        log.notice("interrupted: \(message)")
        report(.interrupted(message))
    }

    @objc private func interruptionEnded(_ note: Notification) {
        log.notice("interruption ended")
        startSession()
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(buffer)
    }

    // MARK: Reporting

    private func fail(_ error: Error) {
        let shade = ShadeError.wrap(error, as: .cameraUnavailable, "The camera couldn't be started.")
        log.error("camera failed: \(shade)")
        report(.unavailable(shade.message))
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }
}
