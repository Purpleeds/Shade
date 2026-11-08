import XCTest
@testable import ShadeCore

final class ShaderSourceTests: XCTestCase {
    func testParamsStructMatchesTheFloatBufferLayout() {
        let pass = ShaderPass(code: "float4 shade() {}", params: [.float("a", 0.5, 0, 1), .color("tint", 1, 0.5, 0.25), .float("b", 2, 0, 4)])
        let source = ShaderSource.source(for: pass)!
        XCTAssertTrue(source.contains("struct ShadeParams {\n    float a;\n    packed_float3 tint;\n    float b;\n};"))
        XCTAssertEqual(ShaderSource.floats(for: pass), [0.5, 1, 0.5, 0.25, 2], "floats are packed in struct order")
    }

    func testEmptyParamsStillProduceAValidStructAndBuffer() {
        let pass = ShaderPass(effect: "invert")
        XCTAssertTrue(ShaderSource.source(for: pass)!.contains("float _unused;"))
        XCTAssertEqual(ShaderSource.floats(for: pass), [0])
    }

    func testUserCodeIsLineMappedSoErrorsPointIntoThePass() {
        let source = ShaderSource.source(for: ShaderPass(code: "float4 shade() {}"))!
        XCTAssertTrue(source.contains("#line 1 \"shade\"\nfloat4 shade() {}\n#line 1 \"entry\""))
    }

    func testParamNamesCannotInjectIntoTheGeneratedSource() {
        let p = ShaderParam.float("x; } kernel void evil() { //", 1, 0, 1)
        XCTAssertEqual(p.name, "xKernelVoidEvil")
        XCTAssertEqual(ShaderParam.sanitizeIdentifier("2fast"), "p2fast")
        XCTAssertEqual(ShaderParam.sanitizeIdentifier("float"), "p_float")
        XCTAssertEqual(ShaderParam.sanitizeIdentifier("__x"), "p__x")
    }
}
