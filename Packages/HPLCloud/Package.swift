// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLCloud",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLCloud", targets: ["HPLCloud"])],
    dependencies: [
        .package(path: "../HPLCore"),
        .package(path: "../HPLInference"),
        .package(path: "../HPLStore"),
    ],
    targets: [
        .target(name: "HPLCloud", dependencies: ["HPLCore", "HPLInference"]),
        .testTarget(name: "HPLCloudTests", dependencies: ["HPLCloud", "HPLCore", "HPLInference", "HPLStore"]),
    ]
)
