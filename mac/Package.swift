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
    targets: [
        .executableTarget(name: "ClipboardSyncMac")
    ]
)
