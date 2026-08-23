// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ThirdHand",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ThirdHand", targets: ["ThirdHand"])
    ],
    targets: [
        .executableTarget(
            name: "ThirdHand",
            path: "Sources/ThirdHand"
        ),
        .testTarget(
            name: "ThirdHandTests",
            dependencies: ["ThirdHand"],
            path: "Tests/ThirdHandTests"
        )
    ]
)
