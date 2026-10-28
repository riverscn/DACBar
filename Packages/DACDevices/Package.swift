// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DACDevices",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DACDeviceKit", targets: ["DACDeviceKit"]),
        .library(name: "IBassoDCTonfa", targets: ["IBassoDCTonfa"]),
        .library(name: "ShanlingUA1II", targets: ["ShanlingUA1II"]),
    ],
    targets: [
        .target(
            name: "DACDeviceKit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "DACHIDTransport",
            dependencies: ["DACDeviceKit"]
        ),
        .target(
            name: "ShanlingUA1II",
            dependencies: ["DACDeviceKit", "DACHIDTransport"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "IBassoDCTonfa",
            dependencies: ["DACDeviceKit", "DACHIDTransport"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DACDeviceKitTests",
            dependencies: ["DACDeviceKit"]
        ),
        .testTarget(
            name: "DACHIDTransportTests",
            dependencies: ["DACDeviceKit", "DACHIDTransport"]
        ),
        .testTarget(
            name: "ShanlingUA1IITests",
            dependencies: ["DACDeviceKit", "ShanlingUA1II"]
        ),
        .testTarget(
            name: "IBassoDCTonfaTests",
            dependencies: ["DACDeviceKit", "IBassoDCTonfa"]
        ),
    ]
)
