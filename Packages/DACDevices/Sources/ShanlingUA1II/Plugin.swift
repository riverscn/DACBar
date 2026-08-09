import DACDeviceKit

extension ShanlingUA1II {
    /// Public integration surface for hosts. Protocol details remain in the
    /// concrete driver and connection types in this target.
    @MainActor
    public struct Plugin: DACDeviceKit.DevicePlugin {
        public let profiles = [ShanlingUA1II.profile]

        public init() {}

        public func devices() throws -> [DACDeviceKit.Device] {
            try ShanlingUA1II.devices()
        }

        public func makeDriver(
            profile: DACDeviceKit.DeviceProfile,
            locationID: UInt32
        ) throws -> any DACDeviceKit.Driver {
            guard supports(profile) else {
                throw DACDeviceKit.DriverFailure.unsupportedModel(profile.id)
            }
            return try ShanlingUA1II.UA1IIDriver(
                locationID: locationID,
                profile: profile)
        }
    }
}
