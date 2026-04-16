// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeliveryMatrix",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DeliveryMatrix",
            path: "Sources/DeliveryMatrix"
        )
    ]
)
