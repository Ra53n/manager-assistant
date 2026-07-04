// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ManagerAssistant",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ManagerAssistant",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/ManagerAssistant",
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "ManagerAssistantTests",
            dependencies: ["ManagerAssistant"],
            path: "Tests/ManagerAssistantTests"
        )
    ]
)
