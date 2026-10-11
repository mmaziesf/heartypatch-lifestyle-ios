// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLPipeline",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLPipeline", targets: ["HPLPipeline"])],
    dependencies: [
        .package(path: "../HPLCore"),
        .package(path: "../HPLInference"),
    ],
    targets: [
        .target(name: "HPLPipeline", dependencies: ["HPLCore", "HPLInference"]),
        .testTarget(name: "HPLPipelineTests", dependencies: ["HPLPipeline", "HPLCore", "HPLInference"]),
    ]
)
