import DACDeviceKit

extension IBassoDCTonfa {
    @MainActor
    public struct Plugin: DACDeviceKit.DevicePlugin {
        public let profiles: [DACDeviceKit.DeviceProfile] = [IBassoDCTonfa.profile]
        public static let previewSettings: [DACDeviceKit.SettingDescriptor] =
            IBassoDCTonfa.TonfaDriver.driverDescriptor.settings

        public init() {
            _ = IBassoDCTonfa.TonfaDriver.driverDescriptor
        }

        public func devices() throws -> [DACDeviceKit.Device] {
            try IBassoDCTonfa.devices()
        }

        public func makeDriver(
            for device: DACDeviceKit.Device
        ) throws -> any DACDeviceKit.Driver {
            try IBassoDCTonfa.TonfaDriver(device: canonicalDevice(for: device))
        }

        func canonicalDevice(
            for device: DACDeviceKit.Device
        ) throws -> DACDeviceKit.Device {
            guard device.profile.id == IBassoDCTonfa.modelID,
                  IBassoDCTonfa.productIDs.contains(device.productID),
                  device.registryEntryID != 0 else {
                throw DACDeviceKit.DriverFailure.unsupportedModel(device.profile.id)
            }
            return DACDeviceKit.Device(
                profile: IBassoDCTonfa.profile,
                productID: device.productID,
                locationID: device.locationID,
                registryEntryID: device.registryEntryID,
                name: device.name)
        }
    }
}
