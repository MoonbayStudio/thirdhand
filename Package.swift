// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ThirdHand",
    defaultLocalization: "ru",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ThirdHand", targets: ["ThirdHand"])
    ],
    targets: [
        .executableTarget(
            name: "ThirdHand",
            path: "Sources/ThirdHand",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ThirdHandTests",
            dependencies: ["ThirdHand"],
            path: "Tests/ThirdHandTests"
        )
    ]
)
