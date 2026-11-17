// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HAMenubar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HAMenubar", path: "Sources/HAMenubar")
    ]
)
