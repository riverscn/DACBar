import DACDeviceKit

extension ShanlingUA1II {
    /// Public integration surface for hosts. Protocol details remain in the
    /// concrete driver and connection types in this target.
    @MainActor
    public struct Plugin: DACDeviceKit.DevicePlugin {
        public let profiles: [DACDeviceKit.DeviceProfile] = [ShanlingUA1II.profile]
        public static let previewSettings: [DACDeviceKit.SettingDescriptor] =
            ShanlingUA1II.UA1IIDriver.driverDescriptor.settings

        public init() {
            // Force capability validation at plug-in composition, before any
            // device appears or SwiftUI consumes setting identities.
            _ = ShanlingUA1II.UA1IIDriver.driverDescriptor
        }

        public func devices() throws -> [DACDeviceKit.Device] {
            try ShanlingUA1II.devices()
        }

        public func makeDriver(
            for device: DACDeviceKit.Device
        ) throws -> any DACDeviceKit.Driver {
            try ShanlingUA1II.UA1IIDriver(device: canonicalDevice(for: device))
        }

        /// Replaces caller-supplied metadata with the profile owned by this
        /// plug-in while retaining the complete discovered service identity.
        /// Internal visibility keeps this pure step directly testable.
        func canonicalDevice(
            for device: DACDeviceKit.Device
        ) throws -> DACDeviceKit.Device {
            guard let profile = profiles.first(where: { $0.id == device.profile.id }) else {
                throw DACDeviceKit.DriverFailure.unsupportedModel(device.profile.id)
            }
            guard profile.hidMatches.contains(where: {
                $0.productID == device.productID
            }), device.registryEntryID != 0 else {
                throw DACDeviceKit.DriverFailure.unsupportedModel(device.profile.id)
            }
            return DACDeviceKit.Device(
                profile: profile,
                productID: device.productID,
                locationID: device.locationID,
                registryEntryID: device.registryEntryID,
                name: device.name)
        }
    }
}
