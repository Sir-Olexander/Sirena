// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sirena",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sirena", targets: ["Sirena"]),
        .executable(name: "sirena-cli", targets: ["SirenaCLI"]),
        .library(name: "SirenaCore", targets: ["SirenaCore"]),
    ],
    targets: [
        .target(
            name: "SirenaCore",
            path: "Sources/SirenaCore"
        ),
        .executableTarget(
            name: "Sirena",
            dependencies: ["SirenaCore"],
            path: "Sources/Sirena"
        ),
        .executableTarget(
            name: "SirenaCLI",
            dependencies: ["SirenaCore"],
            path: "Sources/SirenaCLI"
        ),
        .testTarget(
            name: "SirenaCoreTests",
            dependencies: ["SirenaCore"],
            path: "Tests/SirenaCoreTests"
        ),
    ]
)
