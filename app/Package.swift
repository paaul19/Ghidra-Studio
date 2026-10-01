// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GhidraStudio",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "GhidraStudio",
            path: "Sources/GhidraStudio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
