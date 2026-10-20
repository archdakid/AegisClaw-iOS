// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AegisClaw",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        // Primary iOS App library product consumed by xtool (https://xtool.sh/documentation/xtool/)
        .library(
            name: "AegisClaw",
            targets: ["AegisClawApp"]
        ),
        // Modular umbrella library consumed by XcodeGen (project.yml) and external extensions
        .library(
            name: "AegisClawKit",
            targets: [
                "AegisCore",
                "AegisEdgeLLM",
                "AegisContextMemory",
                "AegisHarness",
                "AegisTools",
                "AegisGateway"
            ]
        ),
        .library(name: "AegisCore", targets: ["AegisCore"]),
        .library(name: "AegisEdgeLLM", targets: ["AegisEdgeLLM"]),
        .library(name: "AegisContextMemory", targets: ["AegisContextMemory"]),
        .library(name: "AegisHarness", targets: ["AegisHarness"]),
        .library(name: "AegisTools", targets: ["AegisTools"]),
        .library(name: "AegisGateway", targets: ["AegisGateway"])
    ],
    dependencies: [
        // Optional drop-in MLX Swift & WhisperKit packages for physical Apple Silicon builds:
        // .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
        // .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "AegisCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AegisEdgeLLM",
            dependencies: ["AegisCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AegisContextMemory",
            dependencies: ["AegisCore", "AegisEdgeLLM"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "AegisTools",
            dependencies: ["AegisCore", "AegisContextMemory"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AegisHarness",
            dependencies: ["AegisCore", "AegisEdgeLLM", "AegisContextMemory", "AegisTools"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AegisGateway",
            dependencies: ["AegisCore", "AegisEdgeLLM", "AegisContextMemory", "AegisHarness", "AegisTools"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AegisClawApp",
            dependencies: [
                "AegisCore",
                "AegisEdgeLLM",
                "AegisContextMemory",
                "AegisHarness",
                "AegisTools",
                "AegisGateway"
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AegisClawTests",
            dependencies: [
                "AegisCore",
                "AegisEdgeLLM",
                "AegisContextMemory",
                "AegisHarness",
                "AegisTools",
                "AegisGateway",
                "AegisClawApp"
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
