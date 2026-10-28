import IOKit
import Testing
@testable import DACDeviceKit
@testable import DACHIDTransport

@Suite("Shared HID transport primitives")
struct DACHIDTransportTests {
    private let profile = DACDeviceKit.DeviceProfile(
        id: .init(rawValue: "test.hid"),
        displayName: "Test HID",
        productNames: ["Test HID"],
        hidMatches: [
            .init(
                vendorID: 1, productID: 2, usagePage: 3, usage: 4,
                inputReportSize: 8, outputReportSize: 8)
        ],
        discoveryKind: .hidService,
        transportKind: .hidReports,
        driverID: .init(rawValue: "test.hid.driver"),
        verification: .experimental)

    @Test("Exact opening identity includes the registry service")
    func openingIdentity() {
        let expected = device(locationID: 7, registryEntryID: 41)
        #expect(DACHIDTransport.DeviceDiscovery.matchesOpeningIdentity(
            expected: expected, actual: expected))
        #expect(!DACHIDTransport.DeviceDiscovery.matchesOpeningIdentity(
            expected: expected,
            actual: device(locationID: 7, registryEntryID: 42)))
        #expect(!DACHIDTransport.DeviceDiscovery.matchesOpeningIdentity(
            expected: expected,
            actual: device(locationID: 8, registryEntryID: 41)))
    }

    @Test("Ambiguous services disappear until discovery settles")
    func discoveryDisambiguation() {
        let first = device(locationID: 7, registryEntryID: 41)
        let replacement = device(locationID: 7, registryEntryID: 42)
        let other = device(locationID: 8, registryEntryID: 43)

        #expect(DACHIDTransport.DeviceDiscovery
            .discardingAmbiguousRegistryEntries([first]) == [first])
        #expect(DACHIDTransport.DeviceDiscovery
            .discardingAmbiguousRegistryEntries([first, replacement]).isEmpty)
        #expect(DACHIDTransport.DeviceDiscovery
            .discardingAmbiguousRegistryEntries([first, replacement, other]) == [other])
    }

    @Test("Output storage survives either completion ordering")
    func outputCompletionOrdering() async {
        let early = DACHIDTransport.ReportSendOperation(frame: [1, 2, 3])
        #expect(early.count == 3)
        #expect(Array(UnsafeBufferPointer(start: early.buffer, count: early.count))
            == [1, 2, 3])
        early.finish(kIOReturnSuccess)
        let earlyResult = await withCheckedContinuation { early.install($0) }
        #expect(earlyResult == kIOReturnSuccess)

        let late = DACHIDTransport.ReportSendOperation(frame: [4, 5])
        let lateResult = await withCheckedContinuation { continuation in
            late.install(continuation)
            late.finish(kIOReturnError)
            late.finish(kIOReturnSuccess)
        }
        #expect(lateResult == kIOReturnError)
    }

    private func device(
        locationID: UInt32,
        registryEntryID: UInt64
    ) -> DACDeviceKit.Device {
        DACDeviceKit.Device(
            profile: profile,
            productID: 2,
            locationID: locationID,
            registryEntryID: registryEntryID,
            name: "Test HID")
    }
}
