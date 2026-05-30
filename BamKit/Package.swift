// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BamKit",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .library(name: "BamCore", targets: ["BamCore"]),
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "BamCore",
            dependencies: ["Yams"]
        ),
        .target(
            name: "AudioEngine",
            dependencies: [
                "BamCore",
                .product(name: "Atomics", package: "swift-atomics"),
            ]
        ),
        .testTarget(
            name: "BamCoreTests",
            dependencies: ["BamCore"]
        ),
        .testTarget(
            name: "AudioEngineTests",
            dependencies: ["AudioEngine"]
        ),
    ]
)
