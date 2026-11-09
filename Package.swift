// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickShot",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "QuickShotCore"),
        .target(name: "ClipboardCore"),
        .executableTarget(name: "QuickShot", dependencies: ["QuickShotCore", "ClipboardCore"]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "QuickShotCoreTests", dependencies: ["QuickShotCore", "TestSupport"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore", "TestSupport"]),
        .testTarget(name: "QuickShotTests", dependencies: ["QuickShot", "QuickShotCore", "ClipboardCore", "TestSupport"]),
    ]
)
