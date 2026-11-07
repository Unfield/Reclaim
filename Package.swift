// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reclaim",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReclaimCore", targets: ["ReclaimCore"]),
        .executable(name: "reclaim", targets: ["reclaim"]),
        .executable(name: "ReclaimApp", targets: ["ReclaimApp"]),
    ],
    targets: [
        .target(name: "ReclaimCore"),
        .executableTarget(name: "reclaim", dependencies: ["ReclaimCore"]),
        .executableTarget(name: "ReclaimApp", dependencies: ["ReclaimCore"]),
        .testTarget(name: "ReclaimCoreTests", dependencies: ["ReclaimCore"]),
    ]
)
