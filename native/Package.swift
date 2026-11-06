// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UIAtlas",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .executable(name: "AtlasApp", targets: ["AtlasApp"]),
    ],
    targets: [
        .target(name: "AtlasCore"),
        .executableTarget(name: "AtlasApp", dependencies: ["AtlasCore"]),
        .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore"]),
    ],
    swiftLanguageModes: [.v5]
)
