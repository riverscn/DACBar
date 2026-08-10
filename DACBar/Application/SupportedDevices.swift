import CoreFoundation
import IOKit.hid
import DACDeviceKit
import ShanlingUA1II

/// The composition root for device plug-ins shipped in this App build.
/// Adding a vendor means registering its profiles and factory here; the UI and
/// session model remain vendor-neutral.
@MainActor
enum SupportedDevices {
    private static let plugins: [any DACDeviceKit.DevicePlugin] = [
        ShanlingUA1II.Plugin(),
    ]

    static let registry = try! DACDeviceKit.DeviceRegistry(
        profiles: plugins.flatMap(\.profiles))

    static var previewProfile: DACDeviceKit.DeviceProfile {
        plugins[0].profiles[0]
    }

    static var previewSettings: [DACDeviceKit.SettingDescriptor] {
        ShanlingUA1II.Plugin.previewSettings
    }

    static func hidMatchingDictionaries() -> CFArray {
        registry.hidMatches.map { match in
            [
                kIOHIDVendorIDKey: match.vendorID,
                kIOHIDProductIDKey: match.productID,
                kIOHIDPrimaryUsagePageKey: match.usagePage,
                kIOHIDPrimaryUsageKey: match.usage,
            ] as CFDictionary
        } as CFArray
    }

    static func devices() throws -> [DACDeviceKit.Device] {
        try plugins.flatMap { try $0.devices() }
    }

    @MainActor
    static func makeDriver(
        for device: DACDeviceKit.Device
    ) throws -> any DACDeviceKit.Driver {
        guard let plugin = plugins.first(where: {
            $0.profiles.contains { $0.id == device.profile.id }
        }) else {
            throw DACDeviceKit.DriverFailure.unsupportedModel(device.profile.id)
        }
        return try plugin.makeDriver(for: device)
    }
}
