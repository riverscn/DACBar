import CoreFoundation
import Foundation
import IOKit
import IOKit.hid
import Testing
@testable import DACBar

@Suite("IOHID device watcher callbacks")
struct DeviceWatcherTests {
    @MainActor
    @Test("Start is idempotent and stop tears down callbacks and scheduling")
    func lifecycleTeardown() throws {
        let fake = DeviceWatcherPlatformFake()
        fake.probes = [.devices([])]
        let watcher = DeviceWatcher(platform: fake.platform())

        try watcher.start()
        try watcher.start()
        watcher.stop()
        watcher.stop()

        #expect(fake.operations == [
            "create", "configure", "install-callbacks", "open",
            "add-event-tracking-mode", "schedule", "probe",
            "clear-callbacks", "unschedule", "close",
        ])
    }

    @MainActor
    @Test("Removal refreshes immediately and publishes its settled snapshot")
    func removalSettlesDeterministically() throws {
        let fake = DeviceWatcherPlatformFake()
        let device = makeDevice(locationID: 7)
        fake.probes = [.devices([device]), .devices([device]), .devices([]), .devices([])]
        let watcher = DeviceWatcher(platform: fake.platform())
        var changes: [[AttachedDevice]] = []
        watcher.onChange = { changes.append($0) }
        try watcher.start()

        fake.sendRemoval(kIOReturnSuccess)
        #expect(watcher.devices == [device])
        #expect(changes.isEmpty)
        #expect(fake.settles.count == 1)

        fake.runLatestSettle()
        #expect(watcher.devices.isEmpty)
        #expect(changes == [[]])

        fake.sendRemoval(kIOReturnSuccess)
        let pendingSettle = try #require(fake.settles.last)
        watcher.stop()
        #expect(pendingSettle.isCancelled)
    }

    @MainActor
    @Test("Probe and IOHID callback failures are surfaced without scheduling")
    func callbackFailures() throws {
        let fake = DeviceWatcherPlatformFake()
        fake.probes = [.devices([]), .failure]
        let watcher = DeviceWatcher(platform: fake.platform())
        var failures: [String] = []
        watcher.onFailure = { failures.append($0) }
        try watcher.start()

        fake.sendMatch(kIOReturnSuccess)
        fake.sendRemoval(kIOReturnError)

        #expect(failures.count == 2)
        #expect(failures[0] == "Expected device probe failure")
        #expect(failures[1] == AppL10n.format(
            "error.hid-notification",
            defaultValue: "HID device notification failed (0x%08X).",
            UInt32(bitPattern: kIOReturnError)))
        #expect(fake.settles.isEmpty)
    }

    @MainActor
    @Test("Manager open failures clear callbacks and close the manager")
    func managerOpenFailureTeardown() {
        let fake = DeviceWatcherPlatformFake()
        fake.openResult = kIOReturnError
        let watcher = DeviceWatcher(platform: fake.platform())

        do {
            try watcher.start()
            Issue.record("Expected IOHID manager open to fail")
        } catch {
            #expect(error.localizedDescription == AppL10n.format(
                "error.hid-watch",
                defaultValue: "Unable to monitor HID device changes (0x%08X).",
                UInt32(bitPattern: kIOReturnError)))
        }

        #expect(fake.operations == [
            "create", "configure", "install-callbacks", "open",
            "clear-callbacks", "close",
        ])
    }

    @MainActor
    private func makeDevice(locationID: UInt32) -> AttachedDevice {
        AttachedDevice(
            profile: SupportedDevices.previewProfile,
            productID: 0x1234,
            locationID: locationID,
            name: "Test DAC",
            portPath: "1-2")
    }
}

private enum DeviceWatcherProbeStep {
    case devices([AttachedDevice])
    case failure
}

private enum DeviceWatcherTestError: LocalizedError {
    case probe

    var errorDescription: String? { "Expected device probe failure" }
}

@MainActor
private final class DeviceWatcherTestSettle: DeviceWatcherSettleCancellation {
    private(set) var isCancelled = false
    let operation: @MainActor @Sendable () -> Void

    init(operation: @escaping @MainActor @Sendable () -> Void) {
        self.operation = operation
    }

    func cancel() {
        isCancelled = true
    }
}

@MainActor
private final class DeviceWatcherPlatformFake {
    final class CallbackToken: NSObject {}

    var openResult = kIOReturnSuccess
    var probes: [DeviceWatcherProbeStep] = []
    private(set) var operations: [String] = []
    private(set) var settles: [DeviceWatcherTestSettle] = []
    private var matchDelivery: (@MainActor @Sendable (IOReturn) -> Void)?
    private var removalDelivery: (@MainActor @Sendable (IOReturn) -> Void)?

    func platform() -> DeviceWatcherPlatform {
        DeviceWatcherPlatform(
            createManager: { [weak self] in
                self?.operations.append("create")
                return IOHIDManagerCreate(
                    kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            },
            configureMatching: { [weak self] _ in
                self?.operations.append("configure")
            },
            installCallbacks: { [weak self] _, matched, removed in
                self?.operations.append("install-callbacks")
                self?.matchDelivery = matched
                self?.removalDelivery = removed
                return CallbackToken()
            },
            clearCallbacks: { [weak self] _ in
                self?.operations.append("clear-callbacks")
                self?.matchDelivery = nil
                self?.removalDelivery = nil
            },
            open: { [weak self] _ in
                self?.operations.append("open")
                return self?.openResult ?? kIOReturnError
            },
            currentRunLoop: { CFRunLoopGetCurrent() },
            addEventTrackingMode: { [weak self] _ in
                self?.operations.append("add-event-tracking-mode")
            },
            schedule: { [weak self] _, _ in
                self?.operations.append("schedule")
            },
            unschedule: { [weak self] _, _ in
                self?.operations.append("unschedule")
            },
            close: { [weak self] _ in
                self?.operations.append("close")
            },
            probe: { [weak self] in
                guard let self else { return [] }
                self.operations.append("probe")
                guard !self.probes.isEmpty else { return [] }
                switch self.probes.removeFirst() {
                case .devices(let devices): return devices
                case .failure: throw DeviceWatcherTestError.probe
                }
            },
            scheduleRemovalSettle: { [weak self] operation in
                let settle = DeviceWatcherTestSettle(operation: operation)
                self?.settles.append(settle)
                return settle
            })
    }

    func sendMatch(_ result: IOReturn) {
        matchDelivery?(result)
    }

    func sendRemoval(_ result: IOReturn) {
        removalDelivery?(result)
    }

    func runLatestSettle() {
        settles.last?.operation()
    }
}
