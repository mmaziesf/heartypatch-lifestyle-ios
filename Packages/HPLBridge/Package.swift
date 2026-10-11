// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLBridge",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLBridge", targets: ["HPLBridge"])],
    dependencies: [
        .package(path: "../HPLCore"),
        .package(path: "../HPLStore"),
    ],
    targets: [
        .target(name: "HPLBridge", dependencies: ["HPLCore"]),
        .testTarget(name: "HPLBridgeTests", dependencies: ["HPLBridge", "HPLCore", "HPLStore"]),
    ]
)
