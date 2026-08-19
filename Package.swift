// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "nitMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "nitMac", targets: ["nitMac"])
    ],
    targets: [
        .executableTarget(
            name: "nitMac",
            path: "Sources/nitMac"
        ),
        .testTarget(
            name: "nitMacTests",
            dependencies: ["nitMac"],
            path: "Tests/nitMacTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
