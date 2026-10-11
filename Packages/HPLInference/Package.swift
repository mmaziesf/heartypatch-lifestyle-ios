// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLInference",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLInference", targets: ["HPLInference"])],
    dependencies: [
        .package(path: "../HPLCore"),
    ],
    targets: [
        .target(name: "HPLInference", dependencies: ["HPLCore"]),
        .testTarget(name: "HPLInferenceTests", dependencies: ["HPLInference", "HPLCore"]),
    ]
)
