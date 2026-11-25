// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PodCraft",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "PodCraft",
            path: "Sources/PodCraft",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PodCraftTests",
            dependencies: ["PodCraft"],
            path: "Tests/PodCraftTests"
        )
    ]
)
