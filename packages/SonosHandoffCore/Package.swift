// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SonosHandoffCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "KeywayChromiumBridgeIPC",
            targets: ["KeywayChromiumBridgeIPC"]
        ),
        .library(
            name: "SonosHandoffCore",
            targets: ["SonosHandoffCore"]
        ),
        .executable(
            name: "sonos-handoff-port",
            targets: ["SonosHandoffPortCLI"]
        ),
        .executable(
            name: "sonos-handoff-safe-grouping-check",
            targets: ["SonosHandoffSafeGroupingCheck"]
        ),
        .executable(
            name: "keyway-chromium-native-host",
            targets: ["KeywayChromiumNativeHost"]
        ),
    ],
    targets: [
        .target(
            name: "KeywayChromiumBridgeIPC",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "SonosHandoffCore"
        ),
        .executableTarget(
            name: "SonosHandoffPortCLI",
            dependencies: ["SonosHandoffCore"]
        ),
        .executableTarget(
            name: "SonosHandoffSafeGroupingCheck",
            dependencies: ["SonosHandoffCore"]
        ),
        .executableTarget(
            name: "KeywayChromiumNativeHost",
            dependencies: ["KeywayChromiumBridgeIPC"]
        ),
        .testTarget(
            name: "KeywayChromiumBridgeIPCTests",
            dependencies: ["KeywayChromiumBridgeIPC"]
        ),
        .testTarget(
            name: "SonosHandoffCoreTests",
            dependencies: ["SonosHandoffCore"]
        ),
    ]
)
