// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "jot-cli",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned to the same FluidAudio revision the app ships (Jot.xcodeproj).
        // Older probes under tools/ still pin 0.15.4 on purpose.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4")
    ],
    targets: [
        .executableTarget(
            name: "jot",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
