// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLCore", targets: ["HPLCore"])],
    targets: [
        .target(name: "HPLCore"),
        .testTarget(name: "HPLCoreTests", dependencies: ["HPLCore"]),
    ]
)
