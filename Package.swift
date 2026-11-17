// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Statty",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Statty",
            path: "Sources/Statty",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
