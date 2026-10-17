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
            dependencies: ["ScreenBlockerKit"],
            path: "Sources/ScreenBlocker"
        ),
        .target(
            name: "ScreenBlockerKit",
            path: "Sources/ScreenBlockerKit"
        ),
        .testTarget(
            name: "ScreenBlockerKitTests",
            dependencies: ["ScreenBlockerKit"],
            path: "Tests/ScreenBlockerKitTests"
        )
    ]
)
