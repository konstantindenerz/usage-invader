// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UsageInvader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UsageInvader",
            path: "Sources/UsageInvader",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
