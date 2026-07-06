// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "jot-cli",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned to the same FluidAudio revision the app ships
        // (see tools/nemotron-probe/Package.swift, tools/diarize-probe/Package.swift).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4")
    ],
    targets: [
        .executableTarget(
            name: "jot",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
