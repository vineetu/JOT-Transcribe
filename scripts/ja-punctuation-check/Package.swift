// swift-tools-version: 5.9
//
// Mini-package that wraps scripts/check-ja-punctuation.swift so it can
// import FluidAudio. FluidAudio is only available on Jot's module path
// via Xcode's SwiftPackageReference — `swift script.swift` against the
// global toolchain has no way to resolve it. Hence this dedicated
// SwiftPM target.
//
// Usage (from repo root):
//   cd scripts/ja-punctuation-check
//   swift run -c release JaPunctuationCheck
//
// FluidAudio version is pinned exact to the same commit Jot.xcodeproj
// resolves (see Jot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/
// Package.resolved → 0.13.6). Keep these in sync manually when bumping.

import PackageDescription

let package = Package(
    name: "JaPunctuationCheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.13.6"),
    ],
    targets: [
        .executableTarget(
            name: "JaPunctuationCheck",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            // Point Sources at this directory; main.swift re-exports the
            // single Swift file at scripts/check-ja-punctuation.swift via
            // a symlink (committed to the repo as `main.swift`).
            path: "Sources/JaPunctuationCheck"
        ),
    ]
)
