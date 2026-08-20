// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "dials",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "neqMac", targets: ["neqMac"]),
        .executable(name: "nitMac", targets: ["nitMac"])
    ],
    targets: [
        .executableTarget(
            name: "neqMac",
            path: "Sources/neqMac"
        ),
        .executableTarget(
            name: "nitMac",
            path: "Sources/nitMac"
        ),
        .testTarget(
            name: "neqMacTests",
            dependencies: ["neqMac"],
            path: "Tests/neqMacTests"
        ),
        .testTarget(
            name: "nitMacTests",
            dependencies: ["nitMac"],
            path: "Tests/nitMacTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
