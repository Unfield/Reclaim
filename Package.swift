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
    dependencies: [
        // In-app updates. Only active in the bundled app (see Updater.swift).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "ReclaimCore"),
        .executableTarget(name: "reclaim", dependencies: ["ReclaimCore"]),
        .executableTarget(
            name: "ReclaimApp",
            dependencies: ["ReclaimCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                // build-app.sh embeds Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "ReclaimCoreTests", dependencies: ["ReclaimCore"]),
    ]
)
