// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "jot-cli",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned to the same FluidAudio revision the app ships
        // (see tools/nemotron-probe/Package.swift, tools/diarize-probe/Package.swift).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
        // The shared text/vocab package — same sibling-checkout convention as
        // the app target's local-path dependency (`../jot-shared` from the
        // repo root, so three levels up from tools/jot-cli/).
        .package(path: "../../../jot-shared"),
    ],
    targets: [
        .executableTarget(
            name: "jot",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "JotTextPipeline", package: "jot-shared"),
                .product(name: "JotVocabCore", package: "jot-shared"),
            ]
        )
    ]
)
