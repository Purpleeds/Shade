// swift-tools-version:5.9
import PackageDescription

// ShadeCore holds everything in Shade that doesn't need UIKit, Metal or AVFoundation:
// the recipe model and validation, built-in effects, Metal source generation, storage and
// migration, the Claude API client and the generate -> compile -> fix pipeline.
// It builds and tests on macOS and Linux: `swift test --package-path Packages/ShadeCore`.
let package = Package(
    name: "ShadeCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ShadeCore", targets: ["ShadeCore"]),
        .executable(name: "shadercheck", targets: ["shadercheck"])
    ],
    targets: [
        .target(name: "ShadeCore"),
        .executableTarget(name: "shadercheck", dependencies: ["ShadeCore"]),
        .testTarget(name: "ShadeCoreTests", dependencies: ["ShadeCore"])
    ]
)
