// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenBlocker",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ScreenBlocker",
            path: "Sources/ScreenBlocker"
        )
    ]
)
