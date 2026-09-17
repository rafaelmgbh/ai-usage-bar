// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AiUsageBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Lógica pura (config de contas + derivação do nome do item de Keychain),
        // separada do executável só pra poder ser testada sem AppKit.
        .target(
            name: "AiUsageCore",
            path: "Sources/AiUsageCore"
        ),
        .executableTarget(
            name: "AiUsageBar",
            dependencies: ["AiUsageCore"],
            path: "Sources/AiUsageBar"
        ),
        .testTarget(
            name: "AiUsageCoreTests",
            dependencies: ["AiUsageCore"],
            path: "Tests/AiUsageCoreTests"
        )
    ]
)
