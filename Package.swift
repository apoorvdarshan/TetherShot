// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TetherShot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TetherShot",
            path: "Sources/TetherShot",
            // Swift 5 concurrency rules keep the AVFoundation delegate/continuation
            // plumbing simple; revisit when we add the wireless backend.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
