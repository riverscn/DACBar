import Testing
@testable import DACDeviceKit
@testable import IBassoDCTonfa

@Suite("iBasso DC-Tonfa protocol")
struct IBassoDCTonfaTests {
    @Test("The profile accepts the official and shipping-hardware PIDs")
    func profileSignatures() {
        #expect(IBassoDCTonfa.profile.displayName == "iBasso DC-Tonfa")
        #expect(IBassoDCTonfa.profile.hidMatches.map(\.productID) == [0x6011, 0xF121])
        for match in IBassoDCTonfa.profile.hidMatches {
            #expect(match.vendorID == 0x2FC6)
            #expect(match.usagePage == 0x0C)
            #expect(match.usage == 1)
            #expect(match.inputReportSize == 8)
            #expect(match.outputReportSize == 8)
        }
    }

    @Test("Read queries match the WebHID protocol")
    func queryFrames() {
        #expect(IBassoDCTonfa.TonfaWireCodec.query(.firmware)
            == [0x58, 0xF1, 0x0E, 0, 0, 0, 0, 0])
        #expect(IBassoDCTonfa.TonfaWireCodec.query(.filter)
            == [0x59, 0x21, 0xDE, 0, 0, 0, 0, 0])
        #expect(IBassoDCTonfa.TonfaWireCodec.query(.volume)
            == [0x42, 0x11, 0xEE, 0, 0, 0, 0, 0])
        #expect(IBassoDCTonfa.TonfaWireCodec.query(.audio)
            == [0x60, 0x31, 0xCE, 0, 0, 0, 0, 0])
        #expect(IBassoDCTonfa.TonfaWireCodec.query(.screen)
            == [0x61, 0x41, 0xBE, 0, 0, 0, 0, 0])
    }

    @Test("Captured-style replies form a complete logical state")
    func responseParsing() throws {
        var state = IBassoDCTonfa.State()
        try IBassoDCTonfa.TonfaWireCodec.apply(
            [0x58, 0xF1, 0x0E, 0, 1, 66, 0x39, 0], to: &state)
        try IBassoDCTonfa.TonfaWireCodec.apply(
            [0x59, 0x21, 0xDE, 0, 4, 0, 0, 0], to: &state)
        try IBassoDCTonfa.TonfaWireCodec.apply(
            [0x42, 0x11, 0xEE, 0, 28, 28, 0, 0], to: &state)
        try IBassoDCTonfa.TonfaWireCodec.apply(
            [0x60, 0x31, 0xCE, 0, 1, 3, 2, 0], to: &state)
        try IBassoDCTonfa.TonfaWireCodec.apply(
            [0x61, 0x41, 0xBE, 0, 1, 1, 2, 0], to: &state)

        #expect(state.firmware == "1.66.39")
        #expect(state.volume == 28)
        #expect(state.filter == 4)
        #expect(state.coaxialOutput == 1)
        #expect(state.balance == -7)
        #expect(state.gain == 2)
        #expect(state.orientation == 1)
        #expect(state.keyControl == 1)
        #expect(state.screenTimeout == 2)
    }

    @Test("Grouped writes preserve adjacent settings")
    func groupedWrites() throws {
        var state = IBassoDCTonfa.State()
        state.gain = 2
        state.balance = -4
        state.coaxialOutput = 1
        state.orientation = 1
        state.keyControl = 1
        state.screenTimeout = 2

        #expect(try IBassoDCTonfa.TonfaWireCodec.encode(
            .balance(5), state: state) == [0x19, 0x30, 0xCF, 0, 1, 15, 2, 0])
        #expect(try IBassoDCTonfa.TonfaWireCodec.encode(
            .screenTimeout(3), state: state) == [0x19, 0x40, 0xBF, 0, 1, 1, 3, 0])
    }

    @Test("The semantic adapter exposes the complete Tonfa control surface")
    func descriptorAndSnapshot() throws {
        let ids = IBassoDCTonfa.TonfaDriver.settings.map(\.id)
        #expect(ids == [
            .volume, .gain, .filter, .coaxialOutput, .keyControl,
            .balance, .uacVersion, .screenTimeout, .orientation,
        ])
        let gain = try #require(IBassoDCTonfa.TonfaDriver.settings.first {
            $0.id == .gain
        })
        #expect(gain.presentation == .options([
            DACDeviceKit.SettingOption(value: 0, label: "Low"),
            DACDeviceKit.SettingOption(value: 1, label: "Medium"),
            DACDeviceKit.SettingOption(value: 2, label: "High"),
        ]))
        var state = IBassoDCTonfa.State()
        state.valid = true
        state.volume = 28
        state.firmware = "1.66.39"
        let snapshot = IBassoDCTonfa.TonfaDriver.snapshot(from: state)
        try IBassoDCTonfa.TonfaDriver.driverDescriptor.validate(snapshot)
        #expect(snapshot.textValues[.uacVersion] == "2.0")
        #expect(snapshot.firmware == "1.66.39")
    }

    @Test("Canonicalization retains the discovered HID service identity")
    @MainActor
    func canonicalDevice() throws {
        let supplied = DACDeviceKit.Device(
            profile: IBassoDCTonfa.profile,
            productID: 0xF121,
            locationID: 0x0110_0000,
            registryEntryID: 42,
            name: "iBasso DC-Tonfa")
        let canonical = try IBassoDCTonfa.Plugin().canonicalDevice(for: supplied)
        #expect(canonical.profile == IBassoDCTonfa.profile)
        #expect(canonical.productID == 0xF121)
        #expect(canonical.locationID == supplied.locationID)
        #expect(canonical.registryEntryID == supplied.registryEntryID)
    }
}
