// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HotkeyToggle",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0")
    ],
    targets: [
        .executableTarget(
            name: "HotkeyToggle",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/HotkeyToggle"
        )
    ]
)
