import QuartzCore
import SwiftUI
import UIKit

/// The live preview. A plain `CAMetalLayer` that the renderer draws into from its own thread,
/// so a heavy look can never make the rest of the interface stutter.
struct MetalView: UIViewRepresentable {
    let renderer: Renderer

    func makeUIView(context: Context) -> RenderSurfaceView {
        let view = RenderSurfaceView()
        view.attach(renderer)
        return view
    }

    func updateUIView(_ uiView: RenderSurfaceView, context: Context) {}
}

final class RenderSurfaceView: UIView {
    /// The preview is drawn at no more than 2× the view's point size. On 3× screens that saves over half the
    /// pixels of the final pass with no visible difference for camera footage.
    static let maximumContentScale: CGFloat = 2

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private weak var renderer: Renderer?
    private var displayLink: CADisplayLink?

    func attach(_ renderer: Renderer) {
        self.renderer = renderer
        backgroundColor = .black
        isOpaque = true
        renderer.attach(layer: metalLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(window?.screen.nativeScale ?? traitCollection.displayScale, RenderSurfaceView.maximumContentScale)
        contentScaleFactor = scale
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        metalLayer.drawableSize = size
        renderer?.setDrawableSize(size)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        // Drives rendering of still images (and animations on them). Camera frames drive themselves.
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func tick() {
        renderer?.displayTick()
    }

    deinit {
        displayLink?.invalidate()
    }
}

/// Breaks the retain cycle between CADisplayLink (which retains its target) and the view.
private final class DisplayLinkProxy: NSObject {
    weak var view: RenderSurfaceView?
    init(_ view: RenderSurfaceView) { self.view = view }
    @objc func tick() { view?.tick() }
}
