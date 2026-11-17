// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UIAtlas",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .executable(name: "AtlasApp", targets: ["AtlasApp"]),
    ],
    targets: [
        .target(name: "AtlasCore", resources: [.process("Resources")]),
        .executableTarget(name: "AtlasApp", dependencies: ["AtlasCore"]),
        .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore"]),
        .testTarget(name: "AtlasAppTests", dependencies: ["AtlasApp", "AtlasCore"]),
    ],
    swiftLanguageModes: [.v5]
)
