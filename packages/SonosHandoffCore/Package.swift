// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SonosHandoffCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SonosHandoffCore",
            targets: ["SonosHandoffCore"]
        ),
        .executable(
            name: "sonos-handoff-port",
            targets: ["SonosHandoffPortCLI"]
        ),
        .executable(
            name: "sonos-handoff-hotkeys",
            targets: ["SonosHandoffHotkeys"]
        ),
    ],
    targets: [
        .target(
            name: "SonosHandoffCore"
        ),
        .executableTarget(
            name: "SonosHandoffPortCLI",
            dependencies: ["SonosHandoffCore"]
        ),
        .executableTarget(
            name: "SonosHandoffHotkeys",
            dependencies: ["SonosHandoffCore"]
        ),
        .testTarget(
            name: "SonosHandoffCoreTests",
            dependencies: ["SonosHandoffCore"]
        ),
    ]
)
