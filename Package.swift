// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickShot",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "QuickShotCore"),
        .executableTarget(name: "QuickShot", dependencies: ["QuickShotCore"]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "QuickShotCoreTests", dependencies: ["QuickShotCore", "TestSupport"]),
        .testTarget(name: "QuickShotTests", dependencies: ["QuickShot", "QuickShotCore", "TestSupport"]),
    ]
)
