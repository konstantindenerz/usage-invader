// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Agents",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Agents",
            path: "Sources/Agents",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
