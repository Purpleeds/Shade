import Foundation

/// Smooth mode: watches how long the GPU takes per frame and lowers the processing resolution
/// while a look is too heavy to hold the frame rate, then raises it again once there is headroom.
///
/// - Steps down when the averaged GPU time passes 85% of the frame budget.
/// - Steps up only when it is below 40% of the budget. The biggest jump between steps costs about 1.9× the work,
///   so stepping up from 40% lands at about 76%, still under the step-down line. That gap prevents flip-flopping.
/// - Waits for the average to settle after each change (about 0.7 s before stepping down again, 1.5 s before stepping up).
public struct FrameRateGovernor: Sendable {
    /// Fractions of the chosen resolution's short side. Pixel count scales with the square.
    public static let scales: [Double] = [1.0, 0.85, 0.7, 0.55, 0.4]

    public let frameBudget: Double
    public private(set) var level = 0
    public private(set) var averageGPUTime: Double?
    private var framesSinceChange = 0

    static let downThreshold = 0.85
    static let upThreshold = 0.40
    static let settleFramesDown = 20
    static let settleFramesUp = 45
    static let smoothing = 0.15

    public init(targetFPS: Double = 30) {
        frameBudget = 1 / max(targetFPS, 1)
    }

    public var scale: Double { FrameRateGovernor.scales[level] }

    /// Feeds the GPU time (seconds) of a finished frame. Returns true when `scale` changed.
    @discardableResult
    public mutating func record(gpuTime: Double) -> Bool {
        guard gpuTime.isFinite, gpuTime >= 0 else { return false }
        let avg = averageGPUTime.map { $0 * (1 - FrameRateGovernor.smoothing) + gpuTime * FrameRateGovernor.smoothing } ?? gpuTime
        averageGPUTime = avg
        framesSinceChange += 1

        if avg > frameBudget * FrameRateGovernor.downThreshold,
           level < FrameRateGovernor.scales.count - 1,
           framesSinceChange >= FrameRateGovernor.settleFramesDown {
            change(by: +1)
            return true
        }
        if avg < frameBudget * FrameRateGovernor.upThreshold,
           level > 0,
           framesSinceChange >= FrameRateGovernor.settleFramesUp {
            change(by: -1)
            return true
        }
        return false
    }

    /// Back to full resolution, e.g. when the look changes or Smooth mode is switched off.
    public mutating func reset() {
        level = 0
        averageGPUTime = nil
        framesSinceChange = 0
    }

    private mutating func change(by delta: Int) {
        level += delta
        framesSinceChange = 0
        // Estimate the new cost from the pixel ratio, so the next decision isn't based on stale numbers.
        if let avg = averageGPUTime {
            let ratio = FrameRateGovernor.scales[level] / FrameRateGovernor.scales[level - delta]
            averageGPUTime = avg * ratio * ratio
        }
    }
}
