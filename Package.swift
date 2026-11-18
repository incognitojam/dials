// swift-tools-version: 6.0

import PackageDescription

var targets: [Target] = [
    .target(name: "RoutingCore"),
    .target(name: "BrightnessCore"),
    .target(name: "EqualizerCore", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
    .target(name: "EqualizerEngineCore", dependencies: ["EqualizerCore", "RoutingCore"]),
    .testTarget(name: "EqualizerEngineCoreTests", dependencies: ["EqualizerEngineCore"]),
    .testTarget(name: "EqualizerCoreTests", dependencies: ["EqualizerCore"]),
    .testTarget(name: "RoutingCoreTests", dependencies: ["RoutingCore"]),
    .testTarget(name: "BrightnessCoreTests", dependencies: ["BrightnessCore"])
]
var products: [Product] = []

#if os(macOS)
products += [
    .executable(name: "neqMac", targets: ["neqMac"]),
    .executable(name: "nitMac", targets: ["nitMac"])
]
targets += [
    .target(name: "DialsKit"),
    .target(name: "EqualizerIO"),
    .executableTarget(name: "neqMac", dependencies: ["DialsKit", "RoutingCore", "EqualizerEngineCore", "EqualizerCore", "EqualizerIO"]),
    .executableTarget(name: "nitMac", dependencies: ["DialsKit", "BrightnessCore"]),
    .testTarget(name: "DialsKitTests", dependencies: ["DialsKit"]),
    .testTarget(name: "neqMacTests", dependencies: ["neqMac", "RoutingCore"])
]
#endif

let package = Package(
    name: "dials",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
