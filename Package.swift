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
        .target(
            name: "DialsKit",
            path: "Sources/DialsKit"
        ),
        .executableTarget(
            name: "neqMac",
            dependencies: ["DialsKit"],
            path: "Sources/neqMac"
        ),
        .executableTarget(
            name: "nitMac",
            dependencies: ["DialsKit"],
            path: "Sources/nitMac"
        ),
        .testTarget(
            name: "DialsKitTests",
            dependencies: ["DialsKit"],
            path: "Tests/DialsKitTests"
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
