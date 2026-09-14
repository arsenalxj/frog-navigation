// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Frog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrogCore", targets: ["FrogCore"]),
        .library(name: "FrogIcons", targets: ["FrogIcons"]),
        .executable(name: "Frog", targets: ["Frog"])
    ],
    targets: [
        .target(name: "FrogCore"),
        .target(name: "FrogIcons"),
        .executableTarget(name: "Frog", dependencies: ["FrogCore", "FrogIcons"]),
        .testTarget(name: "FrogCoreTests", dependencies: ["FrogCore"]),
        .testTarget(name: "FrogTests", dependencies: ["Frog", "FrogCore", "FrogIcons"]),
        .testTarget(name: "FrogIconsTests", dependencies: ["FrogIcons"])
    ],
    swiftLanguageVersions: [.v5]
)
