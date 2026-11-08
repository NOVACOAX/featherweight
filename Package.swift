// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Featherweight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FeatherweightCore", targets: ["FeatherweightCore"]),
        .executable(name: "featherweight", targets: ["FeatherweightCLI"]),
        .executable(name: "FeatherweightHelper", targets: ["FeatherweightHelper"]),
        .executable(name: "FeatherweightApp", targets: ["FeatherweightApp"]),
    ],
    targets: [
        .target(
            name: "FeatherweightCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "FeatherweightCLI",
            dependencies: ["FeatherweightCore"]
        ),
        .executableTarget(
            name: "FeatherweightHelper",
            dependencies: ["FeatherweightCore"]
        ),
        .executableTarget(
            name: "FeatherweightApp",
            dependencies: ["FeatherweightCore"]
        ),
        .testTarget(
            name: "FeatherweightCoreTests",
            dependencies: ["FeatherweightCore"]
        ),
    ]
)
