// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Clabar",
    defaultLocalization: "ru",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Clabar",
            path: "Sources/Clabar",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ClabarTests",
            dependencies: ["Clabar"],
            path: "Tests/ClabarTests"
        )
    ]
)
