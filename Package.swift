// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Clabar",
    defaultLocalization: "ru",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1")
    ],
    targets: [
        .executableTarget(
            name: "Clabar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Clabar",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "ClabarTests",
            dependencies: ["Clabar"],
            path: "Tests/ClabarTests"
        )
    ]
)
