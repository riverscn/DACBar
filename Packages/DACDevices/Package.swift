// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DACDevices",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DACDeviceKit", targets: ["DACDeviceKit"]),
        .library(name: "ShanlingUA1II", targets: ["ShanlingUA1II"]),
    ],
    targets: [
        .target(
            name: "DACDeviceKit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "ShanlingUA1II",
            dependencies: ["DACDeviceKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DACDeviceKitTests",
            dependencies: ["DACDeviceKit"]
        ),
        .testTarget(
            name: "ShanlingUA1IITests",
            dependencies: ["DACDeviceKit", "ShanlingUA1II"]
        ),
    ]
)
