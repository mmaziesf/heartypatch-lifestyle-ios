// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HPLIngest",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HPLIngest", targets: ["HPLIngest"])],
    dependencies: [
        .package(path: "../HPLCore"),
    ],
    targets: [
        .target(name: "HPLIngest", dependencies: ["HPLCore"]),
        .testTarget(name: "HPLIngestTests", dependencies: ["HPLIngest", "HPLCore"]),
    ]
)
