// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AIUsage", path: "Sources/AIUsage")
    ]
)
