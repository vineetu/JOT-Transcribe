// swift-tools-version: 5.10
import PackageDescription

// Standalone CLI POC for CoreAudio device pinning ("Path A").
//
// Answers: can a fresh AVAudioEngine + auAudioUnit.setDeviceID(_:) actually
// capture non-zero samples from a pinned non-default input device on this
// machine? If yes, we have a low-risk drop-in fix for Jot v1.3. If no, we
// know the raw AUHAL path is required.
//
// Independent of the Jot Xcode project and of Tests/AudioCaptureTests. No
// third-party deps — AVFoundation + AudioToolbox only.
let package = Package(
    name: "PinningPOC",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PinPOC",
            path: "Sources/PinPOC"
        ),
    ]
)
