// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Frog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrogCore", targets: ["FrogCore"]),
        .executable(name: "Frog", targets: ["Frog"])
    ],
    targets: [
        .target(name: "FrogCore"),
        .executableTarget(name: "Frog", dependencies: ["FrogCore"], resources: [.copy("Assets")]),
        .testTarget(name: "FrogCoreTests", dependencies: ["FrogCore"]),
        .testTarget(name: "FrogTests", dependencies: ["Frog", "FrogCore"])
    ],
    swiftLanguageVersions: [.v5]
)
