// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CullingBayCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CullingBayCore", targets: ["CullingBayCore"]),
    ],
    targets: [
        .target(name: "CullingBayCore"),
        .testTarget(name: "CullingBayCoreTests", dependencies: ["CullingBayCore"]),
    ]
)
