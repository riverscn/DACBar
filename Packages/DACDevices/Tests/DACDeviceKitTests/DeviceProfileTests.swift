import Testing
@testable import DACDeviceKit

@Suite("Vendor-neutral device core")
struct DeviceProfileTests {
    @Test("Profiles sharing a HID signature are resolved by normalized product name")
    func sharedSignatureUsesProductName() throws {
        let match = DACDeviceKit.HIDMatch(
            vendorID: 1,
            productID: 2,
            usagePage: 1,
            usage: 0x80,
            inputReportSize: 9,
            outputReportSize: 41)
        let first = profile(id: "vendor.one", name: "Vendor One", match: match)
        let second = profile(id: "vendor.two", name: "Vendor Two", match: match)
        let registry = DACDeviceKit.DeviceRegistry(profiles: [first, second])

        let resolved = registry.profile(
            vendorID: 1,
            productID: 2,
            productName: "  USB   Vendor Two  ",
            usagePage: 1,
            usage: 0x80,
            inputReportSize: 9,
            outputReportSize: 41)
        #expect(resolved?.id == second.id)
    }

    @Test("A profile from another discovery backend cannot leak into HID matching")
    func discoveryBackendsStaySeparated() {
        let profile = profile(
            id: "vendor.control",
            name: "Vendor Control",
            match: DACDeviceKit.HIDMatch(
                vendorID: 1,
                productID: 3,
                usagePage: 1,
                usage: 0x80,
                inputReportSize: 9,
                outputReportSize: 41),
            discovery: .usbRegistry)
        #expect(DACDeviceKit.DeviceRegistry(profiles: [profile]).hidMatches.isEmpty)
    }

    @Test("A snapshot validates logical values without knowing a wire protocol")
    func snapshotMutationValidation() throws {
        let volume = DACDeviceKit.SettingDescriptor(
            id: .volume,
            title: "Volume",
            systemImage: "speaker.wave.2",
            group: .audio,
            presentation: .range(
                minimum: 0,
                maximum: 99,
                step: 1,
                format: .number))
        let current = DACDeviceKit.Snapshot(
            valid: true,
            values: [.volume: 10])
        let target = DACDeviceKit.Snapshot(
            valid: true,
            values: [.volume: 20])

        #expect(try current.mutations(to: target, settings: [volume]) == [
            DACDeviceKit.Mutation(setting: .volume, value: 20),
        ])
    }

    private func profile(
        id: String,
        name: String,
        match: DACDeviceKit.HIDMatch,
        discovery: DACDeviceKit.DiscoveryKind = .hidService
    ) -> DACDeviceKit.DeviceProfile {
        DACDeviceKit.DeviceProfile(
            id: DACDeviceKit.ModelID(rawValue: id),
            displayName: name,
            productNames: [name],
            hidMatches: [match],
            discoveryKind: discovery,
            transportKind: .hidReports,
            driverID: DACDeviceKit.DriverID(rawValue: id + ".driver"),
            verification: .experimental)
    }
}
