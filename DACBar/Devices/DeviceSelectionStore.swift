import Foundation

/// Persists only the stable identity of the selected device. Keeping the
/// compatibility key here prevents session state and migration policy from
/// leaking into `DeviceModel`.
struct DeviceSelectionStore {
    static let selectionKey = "selectedDeviceIdentity"
    static let legacySelectionKey = "selectedLocationID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func selectedDevice(in devices: [AttachedDevice]) -> AttachedDevice? {
        if let identity = defaults.string(forKey: Self.selectionKey),
           let device = devices.first(where: {
               $0.persistedSelection == identity
           }) {
            return device
        }

        // Releases before stable model identities persisted only the USB port.
        // Migrate after finding a live match so an unplugged remembered device
        // is not silently replaced before it can be seen again.
        guard let legacy = defaults.object(forKey: Self.legacySelectionKey) as? NSNumber,
              let device = devices.first(where: {
                  $0.locationID == UInt32(truncating: legacy)
              })
        else { return nil }

        replaceSelection(with: device)
        return device
    }

    /// Records an automatic fallback without discarding a legacy selection
    /// that has not yet appeared for migration.
    func save(_ device: AttachedDevice) {
        defaults.set(device.persistedSelection, forKey: Self.selectionKey)
    }

    /// A user choice or completed migration supersedes every older identity.
    func replaceSelection(with device: AttachedDevice) {
        save(device)
        defaults.removeObject(forKey: Self.legacySelectionKey)
    }
}
