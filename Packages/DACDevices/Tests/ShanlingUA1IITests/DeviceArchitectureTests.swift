import Testing
@testable import DACDeviceKit
@testable import ShanlingUA1II

@Suite("Supported-device architecture")
struct DeviceArchitectureTests {

    @Test("The driver String Catalog is embedded and resolves a supported locale")
    func driverLocalization() {
        let value = DeviceL10n.text("settings.volume", defaultValue: "Volume")
        #expect(["Volume", "音量"].contains(value))
    }

    @Test("The supported registry exposes the verified UA1 II HID profile")
    func supportedProfile() throws {
        #expect(ShanlingUA1II.registry.profiles.map(\.id) == [ShanlingUA1II.modelID])
        let profile = try #require(
            ShanlingUA1II.registry.profile(id: ShanlingUA1II.modelID))

        #expect(profile.displayName == "Shanling UA1 II")
        #expect(profile.discoveryKind == .hidService)
        #expect(profile.transportKind == .hidReports)
        #expect(profile.driverID == ShanlingUA1II.driverID)
        #expect(profile.hidMatches.single?.productID == 0x3033)
    }

    @Test("A shared USB signature is disambiguated by normalized product name")
    func sharedSignatureUsesProductName() throws {
        let match = DACDeviceKit.HIDMatch(
            vendorID: 0x20B1,
            productID: 0x301F,
            usagePage: 1,
            usage: 0x80,
            inputReportSize: 8,
            outputReportSize: 8)
        let first = profile(id: "h0", name: "Shanling H0", match: match)
        let second = profile(id: "h7", name: "Shanling H7", match: match)
        let registry = DACDeviceKit.DeviceRegistry(profiles: [first, second])

        let resolved = registry.profile(
            vendorID: 0x20B1,
            productID: 0x301F,
            productName: "  USB   Shanling H7  ",
            usagePage: 1,
            usage: 0x80,
            inputReportSize: 8,
            outputReportSize: 8)
        #expect(resolved?.id == second.id)

        let unknown = registry.profile(
            vendorID: 0x20B1,
            productID: 0x301F,
            productName: "Unknown",
            usagePage: 1,
            usage: 0x80,
            inputReportSize: 8,
            outputReportSize: 8)
        #expect(unknown == nil)
    }

    @Test("A non-HID profile cannot leak into HID discovery")
    func discoveryBackendsStaySeparated() {
        let match = DACDeviceKit.HIDMatch(
            vendorID: 0x20B1,
            productID: 0x3999,
            usagePage: 1,
            usage: 0x80,
            inputReportSize: 8,
            outputReportSize: 8)
        let profile = DACDeviceKit.DeviceProfile(
            id: DACDeviceKit.ModelID(rawValue: "vendor-control"),
            displayName: "Vendor control fixture",
            productNames: ["Vendor control fixture"],
            hidMatches: [match],
            discoveryKind: .usbRegistry,
            transportKind: .vendorControl,
            driverID: ShanlingUA1II.driverID,
            verification: .experimental)
        let registry = DACDeviceKit.DeviceRegistry(profiles: [profile])

        #expect(registry.hidMatches.isEmpty)
        #expect(registry.profile(
            vendorID: match.vendorID,
            productID: match.productID,
            productName: profile.displayName,
            usagePage: match.usagePage,
            usage: match.usage,
            inputReportSize: match.inputReportSize,
            outputReportSize: match.outputReportSize) == nil)
    }

    @Test("Capability validation happens before protocol encoding")
    func capabilityValidation() throws {
        let settings = ShanlingUA1II.UA1IIDriver.settings
        let volume = try #require(settings.first { $0.id == .volume })
        let filter = try #require(settings.first { $0.id == .filter })

        #expect(throws: Never.self) { try volume.validate(99) }
        #expect(throws: DACDeviceKit.DriverFailure.self) { try volume.validate(100) }
        #expect(throws: DACDeviceKit.DriverFailure.self) { try filter.validate(5) }
    }

    @Test("The semantic adapter owns signed and biased UA1 II wire values")
    func semanticWireMapping() throws {
        let balance = DACDeviceKit.Mutation(setting: .balance, value: -12)
        let offset = DACDeviceKit.Mutation(setting: .screenOffset, value: 10)

        #expect(try ShanlingUA1II.UA1IIDriver.write(from: balance)
            == ShanlingUA1II.Write(.balance, UInt8(bitPattern: -12)))
        #expect(try ShanlingUA1II.UA1IIDriver.write(from: offset)
            == ShanlingUA1II.Write(.screenOffset, 60))
        #expect(ShanlingUA1II.UA1IIDriver.mutation(
            from: try ShanlingUA1II.Write(.screenOffset, 55))
            == DACDeviceKit.Mutation(setting: .screenOffset, value: 5))
    }

    private func profile(
        id: String,
        name: String,
        match: DACDeviceKit.HIDMatch
    ) -> DACDeviceKit.DeviceProfile {
        DACDeviceKit.DeviceProfile(
            id: DACDeviceKit.ModelID(rawValue: id),
            displayName: name,
            productNames: [name],
            hidMatches: [match],
            discoveryKind: .hidService,
            transportKind: .interruptEndpoints,
            driverID: ShanlingUA1II.driverID,
            verification: .experimental)
    }
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}
