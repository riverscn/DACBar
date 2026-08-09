import Foundation
import DACDeviceKit

/// One attached dongle, as the UI sees it.
///
/// Some USB DACs do not expose a unique serial number, so the physical port
/// path is part of the persisted identity and the on-screen disambiguation.
struct AttachedDevice: Identifiable, Equatable {
    let profile: DACDeviceKit.DeviceProfile
    let productID: Int
    let locationID: UInt32
    let registryEntryID: UInt64
    let name: String
    let portPath: String

    var id: DACDeviceKit.Device.ID {
        DACDeviceKit.Device.ID(model: profile.id, locationID: locationID)
    }

    var persistedSelection: String {
        "\(profile.id.rawValue):\(locationID)"
    }

    /// Shown only when more than one is attached, where the bare model name
    /// would be the same for every row.
    var disambiguatedName: String {
        AppL10n.format(
            "device.name-with-port",
            defaultValue: "%1$@ (Port %2$@)",
            name, portPath)
    }

    init(
        profile: DACDeviceKit.DeviceProfile,
        productID: Int,
        locationID: UInt32,
        registryEntryID: UInt64 = 0,
        name: String,
        portPath: String
    ) {
        self.profile = profile
        self.productID = productID
        self.locationID = locationID
        self.registryEntryID = registryEntryID
        self.name = name
        self.portPath = portPath
    }

    /// Built from the app's own registry scan, which is how the list stays live
    /// without waking the daemon on every plug event.
    init(_ device: DACDeviceKit.Device) {
        profile = device.profile
        productID = device.productID
        locationID = device.locationID
        registryEntryID = device.registryEntryID
        name = device.name
        portPath = device.portPath
    }
}
