import XCTest
@testable import ShadeCore

final class ProcessingResolutionTests: XCTestCase {
    func testLabelsMatchTheRealPixelCounts() {
        XCTAssertEqual(ProcessingResolution.allCases.map(\.megapixelLabel), ["0.5 MP", "0.9 MP", "2.1 MP", "3.7 MP", "8.3 MP"])
        XCTAssertEqual(ProcessingResolution.p1080.dimensionsLabel, "1080 × 1920")
        XCTAssertEqual(ProcessingResolution.defaultValue, .p1080, "the default matches what Shade 1.0 processed")
    }

    func testEachOptionAsksTheCameraForEnoughPixels() {
        let tierShort: [CaptureTier: Int] = [.hd720: 720, .hd1080: 1080, .uhd4K: 2160]
        for option in ProcessingResolution.allCases {
            XCTAssertGreaterThanOrEqual(tierShort[option.captureTier]!, option.shortSide, option.rawValue)
        }
    }

    func testProcessingSizeKeepsAspectAndNeverUpscales() {
        let portrait1080 = PixelSize(width: 1080, height: 1920)
        XCTAssertEqual(ProcessingResolution.p720.processingSize(input: portrait1080), PixelSize(width: 720, height: 1280))
        XCTAssertEqual(ProcessingResolution.p2160.processingSize(input: portrait1080), portrait1080, "never larger than the input")
        XCTAssertEqual(ProcessingResolution.p1080.processingSize(input: portrait1080, scale: 0.5), PixelSize(width: 540, height: 960))

        let photo = PixelSize(width: 3000, height: 4000) // 4:3 still image
        let size = ProcessingResolution.p1080.processingSize(input: photo)
        XCTAssertEqual(size.shortSide, 1080)
        XCTAssertEqual(Double(size.height) / Double(size.width), 4.0 / 3.0, accuracy: 0.01)
    }

    func testProcessingSizesAreEvenAndSane() {
        for option in ProcessingResolution.allCases {
            for scale in FrameRateGovernor.scales {
                let s = option.processingSize(input: PixelSize(width: 2161, height: 3841), scale: scale)
                XCTAssertEqual(s.width % 2, 0)
                XCTAssertEqual(s.height % 2, 0)
                XCTAssertGreaterThanOrEqual(s.width, 64)
            }
        }
        XCTAssertEqual(ProcessingResolution.p540.processingSize(input: PixelSize(width: 0, height: 0)), PixelSize(width: 64, height: 64))
    }

    func testUnknownStoredValuesFallBackToTheDefault() {
        XCTAssertEqual(ProcessingResolution(storedValue: "p720"), .p720)
        XCTAssertEqual(ProcessingResolution(storedValue: "16k"), .defaultValue)
        XCTAssertEqual(ProcessingResolution(storedValue: nil), .defaultValue)
    }
}

final class FrameRateGovernorTests: XCTestCase {
    /// A look whose GPU time scales with pixel count: `fullCost` seconds at scale 1.
    func simulate(fullCost: Double, frames: Int, governor: inout FrameRateGovernor) -> [Int] {
        var levels: [Int] = []
        for _ in 0..<frames {
            let s = governor.scale
            governor.record(gpuTime: fullCost * s * s)
            levels.append(governor.level)
        }
        return levels
    }

    func testLightLooksStayAtFullResolution() {
        var g = FrameRateGovernor(targetFPS: 30)
        _ = simulate(fullCost: 0.010, frames: 300, governor: &g)
        XCTAssertEqual(g.level, 0)
        XCTAssertEqual(g.scale, 1)
    }

    func testHeavyLooksStepDownUntilTheyFitTheBudget() {
        var g = FrameRateGovernor(targetFPS: 30)
        _ = simulate(fullCost: 0.060, frames: 400, governor: &g) // twice the 33 ms budget
        let s = g.scale
        XCTAssertLessThan(0.060 * s * s, g.frameBudget * 0.85 + 0.0001, "settles at a scale that fits")
        XCTAssertGreaterThan(g.level, 0)
    }

    func testDoesNotOscillateOnceSettled() {
        for cost in [0.03, 0.045, 0.06, 0.09, 0.15] {
            var g = FrameRateGovernor(targetFPS: 30)
            _ = simulate(fullCost: cost, frames: 600, governor: &g)
            let tail = simulate(fullCost: cost, frames: 600, governor: &g)
            XCTAssertEqual(Set(tail).count, 1, "level kept changing for cost \(cost): \(Set(tail))")
        }
    }

    func testRecoversWhenTheLookGetsLighter() {
        var g = FrameRateGovernor(targetFPS: 30)
        _ = simulate(fullCost: 0.08, frames: 400, governor: &g)
        XCTAssertGreaterThan(g.level, 0)
        _ = simulate(fullCost: 0.005, frames: 600, governor: &g)
        XCTAssertEqual(g.level, 0)
    }

    func testIgnoresGarbageTimingsAndResets() {
        var g = FrameRateGovernor()
        XCTAssertFalse(g.record(gpuTime: .nan))
        XCTAssertFalse(g.record(gpuTime: -1))
        XCTAssertNil(g.averageGPUTime)
        _ = simulate(fullCost: 0.1, frames: 200, governor: &g)
        g.reset()
        XCTAssertEqual(g.level, 0)
        XCTAssertNil(g.averageGPUTime)
    }
}

final class StructureKeyTests: XCTestCase {
    func testSliderValuesDoNotChangeTheKeyButStructureDoes() {
        let a = ShaderPass.builtIn("bloom", ["intensity": [0.5]])
        let b = ShaderPass.builtIn("bloom", ["intensity": [3.0]])
        XCTAssertEqual(ShaderSource.structureKey(for: a), ShaderSource.structureKey(for: b))
        XCTAssertNotEqual(ShaderSource.structureKey(for: a), ShaderSource.structureKey(for: ShaderPass(effect: "blur")))

        let c1 = ShaderPass(code: "float4 shade() {}", params: [.float("k", 1, 0, 2)])
        let c2 = ShaderPass(code: "float4 shade() {}", params: [.color("k", 1, 1, 1)])
        XCTAssertNotEqual(ShaderSource.structureKey(for: c1), ShaderSource.structureKey(for: c2), "param types change the generated struct")
        XCTAssertNil(ShaderSource.structureKey(for: ShaderPass()))
    }
}
