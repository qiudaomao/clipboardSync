// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardSyncMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClipboardSyncMac", targets: ["ClipboardSyncMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "ClipboardSyncCore"),
        .executableTarget(
            name: "ClipboardSyncMac",
            dependencies: ["Sparkle", "ClipboardSyncCore"]
        ),
        .testTarget(name: "ClipboardSyncCoreTests", dependencies: ["ClipboardSyncCore"])
    ]
)
