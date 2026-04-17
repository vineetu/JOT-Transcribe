// swift-tools-version: 5.10
import PackageDescription

// Standalone package for the audio-capture regression harness.
//
// Does not depend on Jot.xcodeproj or any third-party package — keeps the
// test fast and self-contained. See docs/plans/audio-test-harness.md for the
// full rationale; short version: Phase 1 lands the harness additively with
// zero source refactor, Phase 2 merges the pipeline back into the main app
// target and re-points this at the real symbol.
let package = Package(
    name: "AudioCaptureTests",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioPipelineHarness", targets: ["AudioPipelineHarness"]),
    ],
    targets: [
        .target(
            name: "AudioPipelineHarness",
            path: "Sources/AudioPipelineHarness"
        ),
        .testTarget(
            name: "AudioCaptureTests",
            dependencies: ["AudioPipelineHarness"],
            path: "Tests/AudioCaptureTests"
        ),
    ]
)
