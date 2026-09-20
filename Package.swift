// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContainerSweeper",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ContainerSweeper", targets: ["ContainerSweeper"]),
        .library(name: "SweeperCore", targets: ["SweeperCore"]),
    ],
    targets: [
        .target(name: "SweeperCore"),
        .executableTarget(
            name: "ContainerSweeper",
            dependencies: ["SweeperCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "SweeperCoreTests", dependencies: ["SweeperCore"]),
    ]
)
