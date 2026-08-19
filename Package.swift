// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "neqMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "neqMac", targets: ["neqMac"])
    ],
    targets: [
        .executableTarget(
            name: "neqMac",
            path: "Sources/neqMac"
        ),
        .testTarget(
            name: "neqMacTests",
            dependencies: ["neqMac"],
            path: "Tests/neqMacTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
