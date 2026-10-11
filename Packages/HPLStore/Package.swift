// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLStore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLStore", targets: ["HPLStore"])],
    dependencies: [
        .package(path: "../HPLCore"),
    ],
    targets: [
        .target(name: "HPLStore", dependencies: ["HPLCore"]),
        .testTarget(name: "HPLStoreTests", dependencies: ["HPLStore", "HPLCore"]),
    ]
)
