import Testing
@testable import DACDeviceKit

@Suite("Vendor-neutral device core")
struct DeviceProfileTests {
    @Test("Profiles cannot share a HID signature across plug-in ownership")
    func sharedSignatureFailsComposition() throws {
        let match = DACDeviceKit.HIDMatch(
            vendorID: 1,
            productID: 2,
            usagePage: 1,
            usage: 0x80,
            inputReportSize: 9,
            outputReportSize: 41)
        let first = profile(id: "vendor.one", name: "Vendor One", match: match)
        let second = profile(id: "vendor.two", name: "Vendor Two", match: match)
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try DACDeviceKit.DeviceRegistry(profiles: [first, second])
        }
    }

    @Test("A profile from another discovery backend cannot leak into HID matching")
    func discoveryBackendsStaySeparated() throws {
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
        #expect(try DACDeviceKit.DeviceRegistry(profiles: [profile]).hidMatches.isEmpty)
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

    @Test("Registry construction rejects duplicate identities and ambiguous HID signatures")
    func invalidRegistryConfiguration() throws {
        let match = DACDeviceKit.HIDMatch(
            vendorID: 1,
            productID: 2,
            usagePage: 1,
            usage: 0x80,
            inputReportSize: 9,
            outputReportSize: 41)
        let first = profile(id: "vendor.one", name: "Shared", match: match)

        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try DACDeviceKit.DeviceRegistry(profiles: [first, first])
        }
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try DACDeviceKit.DeviceRegistry(profiles: [
                first,
                profile(
                    id: "vendor.two",
                    name: "Other",
                    match: DACDeviceKit.HIDMatch(
                        vendorID: 2,
                        productID: 3,
                        usagePage: 1,
                        usage: 0x80,
                        inputReportSize: 9,
                        outputReportSize: 41),
                    driverID: "vendor.one.driver"),
            ])
        }
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try DACDeviceKit.DeviceRegistry(profiles: [
                first,
                profile(id: "vendor.two", name: "Shared", match: match),
            ])
        }
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            let duplicateMatch = DACDeviceKit.DeviceProfile(
                id: DACDeviceKit.ModelID(rawValue: "vendor.duplicate"),
                displayName: "Duplicate",
                productNames: ["Duplicate"],
                hidMatches: [match, match],
                discoveryKind: .hidService,
                transportKind: .hidReports,
                driverID: DACDeviceKit.DriverID(rawValue: "vendor.duplicate.driver"),
                verification: .experimental)
            _ = try DACDeviceKit.DeviceRegistry(profiles: [duplicateMatch])
        }
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            let undiscoverable = DACDeviceKit.DeviceProfile(
                id: DACDeviceKit.ModelID(rawValue: "vendor.missing-match"),
                displayName: "Missing match",
                productNames: ["Missing match"],
                hidMatches: [],
                discoveryKind: .hidService,
                transportKind: .hidReports,
                driverID: DACDeviceKit.DriverID(rawValue: "vendor.missing-match.driver"),
                verification: .experimental)
            _ = try DACDeviceKit.DeviceRegistry(profiles: [undiscoverable])
        }
    }

    @Test("Driver descriptor construction rejects invalid settings and retry policy")
    func invalidDriverConfiguration() throws {
        let volume = descriptor(
            id: .volume,
            presentation: .range(minimum: 0, maximum: 99, step: 1, format: .number))
        let duplicateOptions = descriptor(
            id: .filter,
            presentation: .menu([
                DACDeviceKit.SettingOption(value: 0, label: "A"),
                DACDeviceKit.SettingOption(value: 0, label: "B"),
            ]))
        let invalidRange = descriptor(
            id: .balance,
            presentation: .range(minimum: 10, maximum: 0, step: 0, format: .number))

        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try driverDescriptor(settings: [volume, volume])
        }
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try driverDescriptor(settings: [duplicateOptions])
        }
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try driverDescriptor(settings: [invalidRange])
        }
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try driverDescriptor(settings: [volume], delays: [.milliseconds(-1)])
        }
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try driverDescriptor(settings: [volume], writeRetryLimit: -1)
        }

        let emptyGroup = DACDeviceKit.SettingGroup(id: "  ", title: "Empty")
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try driverDescriptor(settings: [descriptor(
                id: .volume,
                presentation: .toggle,
                group: emptyGroup)])
        }

        let firstGroup = DACDeviceKit.SettingGroup(
            id: "shared", title: "First", isCollapsible: false)
        let conflictingGroup = DACDeviceKit.SettingGroup(
            id: "shared", title: "Second", isCollapsible: true)
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            _ = try driverDescriptor(settings: [
                descriptor(id: .volume, presentation: .toggle, group: firstGroup),
                descriptor(id: .gain, presentation: .toggle, group: conflictingGroup),
            ])
        }
        #expect(throws: Never.self) {
            _ = try driverDescriptor(settings: [
                descriptor(id: .volume, presentation: .toggle, group: firstGroup),
                descriptor(id: .gain, presentation: .toggle, group: firstGroup),
            ])
        }
    }

    @Test("Direct range validation throws for reversed configuration")
    func reversedRangeValidationDoesNotTrap() {
        let reversed = descriptor(
            id: .volume,
            presentation: .range(
                minimum: 10, maximum: 0, step: 1, format: .number))

        #expect(throws: DACDeviceKit.DriverFailure.self) {
            try reversed.validate(5)
        }
    }

    @Test("Complete logical snapshots contain every declared setting")
    func incompleteSnapshotIsRejected() throws {
        let volume = descriptor(
            id: .volume,
            presentation: .range(minimum: 0, maximum: 99, step: 1, format: .number))
        let gain = descriptor(
            id: .gain,
            presentation: .toggle)
        let descriptor = try driverDescriptor(settings: [volume, gain])

        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            try descriptor.validate(DACDeviceKit.Snapshot(
                valid: true, values: [.volume: 20]))
        }
        #expect(throws: DACDeviceKit.ConfigurationFailure.self) {
            try descriptor.validate(DACDeviceKit.Snapshot(
                valid: true, values: [.volume: 100, .gain: 0]))
        }
        #expect(throws: Never.self) {
            try descriptor.validate(DACDeviceKit.Snapshot(
                valid: true, values: [.volume: 20, .gain: 1]))
        }
    }

    private func descriptor(
        id: DACDeviceKit.SettingID,
        presentation: DACDeviceKit.SettingPresentation,
        group: DACDeviceKit.SettingGroup = .audio
    ) -> DACDeviceKit.SettingDescriptor {
        DACDeviceKit.SettingDescriptor(
            id: id,
            title: id.rawValue,
            systemImage: "slider.horizontal.3",
            group: group,
            presentation: presentation)
    }

    private func driverDescriptor(
        settings: [DACDeviceKit.SettingDescriptor],
        delays: [Duration] = [],
        writeRetryLimit: Int = 0
    ) throws -> DACDeviceKit.DriverDescriptor {
        try DACDeviceKit.DriverDescriptor(
            settings: settings,
            readback: .complete,
            confirmation: .acknowledgement,
            readRetryDelays: delays,
            writeRetryLimit: writeRetryLimit)
    }

    private func profile(
        id: String,
        name: String,
        match: DACDeviceKit.HIDMatch,
        discovery: DACDeviceKit.DiscoveryKind = .hidService,
        driverID: String? = nil
    ) -> DACDeviceKit.DeviceProfile {
        DACDeviceKit.DeviceProfile(
            id: DACDeviceKit.ModelID(rawValue: id),
            displayName: name,
            productNames: [name],
            hidMatches: [match],
            discoveryKind: discovery,
            transportKind: .hidReports,
            driverID: DACDeviceKit.DriverID(rawValue: driverID ?? id + ".driver"),
            verification: .experimental)
    }
}
