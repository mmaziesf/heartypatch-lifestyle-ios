// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLHealth",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLHealth", targets: ["HPLHealth"])],
    dependencies: [
        .package(path: "../HPLCore"),
    ],
    targets: [
        .target(name: "HPLHealth", dependencies: ["HPLCore"]),
        .testTarget(name: "HPLHealthTests", dependencies: ["HPLHealth", "HPLCore"]),
    ]
)
