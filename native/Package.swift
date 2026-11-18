// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fudehand",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FudehandCore", targets: ["FudehandCore"]),
        .executable(name: "FudehandApp", targets: ["FudehandApp"]),
    ],
    targets: [
        .target(name: "FudehandCore", resources: [.process("Resources")]),
        .executableTarget(
            name: "FudehandApp",
            dependencies: ["FudehandCore"],
            swiftSettings: [.enableUpcomingFeature("InferSendableFromCaptures")]
        ),
        .testTarget(name: "FudehandCoreTests", dependencies: ["FudehandCore"]),
        .testTarget(name: "FudehandAppTests", dependencies: ["FudehandApp", "FudehandCore"]),
    ],
    swiftLanguageModes: [.v5]
)
