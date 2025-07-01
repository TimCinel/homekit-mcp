// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HomeKitMCP",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "HomeKitMCPCore",
            targets: ["HomeKitMCPCore"]
        ),
    ],
    targets: [
        .target(
            name: "HomeKitMCPCore",
            dependencies: [],
            path: "Sources/HomeKitMCPCore"
        ),
        .testTarget(
            name: "HomeKitMCPCoreTests",
            dependencies: ["HomeKitMCPCore"],
            path: "Tests/HomeKitMCPCoreTests"
        ),
    ]
)