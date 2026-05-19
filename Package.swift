// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeViewer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeViewer",
            path: "Sources/ClaudeViewer"
        )
    ]
)
