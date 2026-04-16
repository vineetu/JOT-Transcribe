// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OverlayPlacement",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OverlayPlacement",
            path: "Sources/OverlayPlacement"
        )
    ]
)
