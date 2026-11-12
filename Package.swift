// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LumaWall",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LumaWallCore", targets: ["LumaWallCore"]),
        .executable(name: "LumaWall", targets: ["LumaWallApp"]),
        .executable(name: "LumaWallBenchmarks", targets: ["LumaWallBenchmarks"]),
    ],
    targets: [
        .target(name: "LumaWallCore"),
        .executableTarget(
            name: "LumaWallApp",
            dependencies: ["LumaWallCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "LumaWallBenchmarks",
            dependencies: ["LumaWallCore"],
            path: "Tools/Benchmarks/Sources/LumaWallBenchmarks"
        ),
        .testTarget(name: "LumaWallCoreTests", dependencies: ["LumaWallCore"]),
    ]
)
