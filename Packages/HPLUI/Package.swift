// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLUI",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLUI", targets: ["HPLUI"])],
    dependencies: [
        .package(path: "../HPLCore"),
        .package(path: "../HPLStore"),
        .package(path: "../HPLHealth"),
        .package(path: "../HPLIngest"),
        .package(path: "../HPLInference"),
        .package(path: "../HPLPipeline"),
        .package(path: "../HPLBridge"),
        .package(path: "../HPLCloud"),
    ],
    targets: [
        .target(name: "HPLUI", dependencies: ["HPLCore", "HPLStore", "HPLHealth", "HPLIngest", "HPLInference", "HPLPipeline", "HPLBridge", "HPLCloud"]),
        .testTarget(name: "HPLUITests", dependencies: [
            "HPLUI", "HPLCore", "HPLStore", "HPLHealth", "HPLIngest", "HPLInference", "HPLPipeline", "HPLBridge", "HPLCloud",
        ]),
    ]
)
