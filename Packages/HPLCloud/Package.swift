// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLCloud",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLCloud", targets: ["HPLCloud"])],
    dependencies: [
        .package(path: "../HPLCore"),
    ],
    targets: [
        .target(name: "HPLCloud", dependencies: ["HPLCore"]),
        .testTarget(name: "HPLCloudTests", dependencies: ["HPLCloud", "HPLCore"]),
    ]
)
