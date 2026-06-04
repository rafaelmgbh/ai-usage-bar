// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AiUsageBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AiUsageBar",
            path: "Sources/AiUsageBar"
        )
    ]
)
