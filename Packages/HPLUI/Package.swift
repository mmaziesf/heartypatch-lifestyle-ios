// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLUI",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLUI", targets: ["HPLUI"])],
    dependencies: [
        .package(path: "../HPLCore"),
        .package(path: "../HPLStore"),
        .package(path: "../HPLInference"),
        .package(path: "../HPLPipeline"),
    ],
    targets: [
        .target(name: "HPLUI", dependencies: ["HPLCore", "HPLStore", "HPLInference", "HPLPipeline"]),
        .testTarget(name: "HPLUITests", dependencies: ["HPLUI", "HPLCore", "HPLStore", "HPLInference", "HPLPipeline"]),
    ]
)
