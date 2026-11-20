// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pocket",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pocket",
            path: "Sources/Pocket",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
