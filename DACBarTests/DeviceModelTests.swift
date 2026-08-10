import Foundation
import Testing
@testable import DACBar
@testable import DACDeviceKit

private enum TestFailure: Error {
    case transport
}

private enum TestDevice {
    static let profile = DACDeviceKit.DeviceProfile(
        id: DACDeviceKit.ModelID(rawValue: "test.fixture"),
        displayName: "Test DAC",
        productNames: ["Test DAC"],
        hidMatches: [
            DACDeviceKit.HIDMatch(
                vendorID: 1,
                productID: 2,
                usagePage: 1,
                usage: 0x80,
                inputReportSize: 9,
                outputReportSize: 41)
        ],
        discoveryKind: .hidService,
        transportKind: .hidReports,
        driverID: DACDeviceKit.DriverID(rawValue: "test.fixture.driver"),
        verification: .experimental)

    static let settings: [DACDeviceKit.SettingDescriptor] = [
        descriptor(.volume, 0...99),
        descriptor(.gain, 0...1),
        descriptor(.filter, 0...4),
        descriptor(.balance, -12...12),
        descriptor(.brightness, 0...10),
        descriptor(.screenTimeout, 0...60),
        descriptor(.orientation, 0...3),
        descriptor(.screenOffset, 0...10),
    ]

    private static func descriptor(
        _ id: DACDeviceKit.SettingID,
        _ range: ClosedRange<Int>
    ) -> DACDeviceKit.SettingDescriptor {
        DACDeviceKit.SettingDescriptor(
            id: id,
            title: id.rawValue,
            systemImage: "slider.horizontal.3",
            group: .audio,
            presentation: .range(
                minimum: range.lowerBound,
                maximum: range.upperBound,
                step: 1,
                format: .number))
    }
}

@MainActor
private final class FakeWatcher: DeviceWatching {
    var devices: [AttachedDevice]
    var onChange: (([AttachedDevice]) -> Void)?
    var onFailure: ((String) -> Void)?
    var probeResult: Result<[AttachedDevice], any Error>
    var startError: (any Error)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(devices: [AttachedDevice], startError: (any Error)? = nil) {
        self.devices = devices
        self.startError = startError
        self.probeResult = .success(devices)
    }

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }
    func stop() { stopCount += 1 }
    func probe() throws -> [AttachedDevice] { try probeResult.get() }

    func publish(_ devices: [AttachedDevice]) {
        self.devices = devices
        probeResult = .success(devices)
        onChange?(devices)
    }
}

@MainActor
private final class FakeConnection: DeviceDriver {
    let profile = TestDevice.profile
    let descriptor: DACDeviceKit.DriverDescriptor

    var onChange: ((DACDeviceKit.Mutation) -> Void)?
    var onConfirmed: ((DACDeviceKit.Mutation) -> Void)?
    var onDropped: ((DACDeviceKit.Mutation) -> Void)?
    var onRemoved: (() -> Void)?

    var immediateRead: DACDeviceKit.Snapshot?
    var readResults: [Result<DACDeviceKit.Snapshot, any Error>] = []
    var readContinuation: CheckedContinuation<DACDeviceKit.Snapshot, any Error>?
    var submissionError: (any Error)?
    private(set) var submitted: [DACDeviceKit.Mutation] = []
    private(set) var closeCount = 0
    private(set) var readCount = 0

    init(
        state: DACDeviceKit.Snapshot? = nil,
        descriptor: DACDeviceKit.DriverDescriptor? = nil
    ) {
        immediateRead = state
        self.descriptor = descriptor ?? (try! DACDeviceKit.DriverDescriptor(
            settings: TestDevice.settings,
            readback: .complete,
            confirmation: .acknowledgement,
            readRetryDelays: [.milliseconds(600), .seconds(1)],
            writeRetryLimit: 1))
    }

    func read() async throws -> DACDeviceKit.Snapshot {
        readCount += 1
        if !readResults.isEmpty { return try readResults.removeFirst().get() }
        if let immediateRead { return immediateRead }
        return try await withCheckedThrowingContinuation { continuation in
            readContinuation = continuation
        }
    }

    func submit(_ write: DACDeviceKit.Mutation) async throws {
        submitted.append(write)
        if let submissionError { throw submissionError }
    }

    func close() { closeCount += 1 }

    func completeRead(_ state: DACDeviceKit.Snapshot) {
        let continuation = readContinuation
        readContinuation = nil
        continuation?.resume(returning: state)
    }
}

@Suite("Device model session state")
@MainActor
struct DeviceModelTests {

    @Test("A stale read and callbacks cannot overwrite a newly selected device")
    func staleSessionIsIgnored() async throws {
        let first = device(location: 0x0110_0000, registry: 1)
        let second = device(location: 0x0210_0000, registry: 2)
        let watcher = FakeWatcher(devices: [first])
        let connectionA = FakeConnection()
        let connectionB = FakeConnection(state: state(volume: 72))
        let model = DeviceModel(watcher: watcher) { device in
            device.locationID == first.locationID ? connectionA : connectionB
        }

        await Task.yield()
        watcher.publish([second])
        try await waitUntil { model.phase == .ready }
        #expect(model.draft.volume == 72)

        connectionA.completeRead(state(volume: 11))
        connectionA.onChange?(DACDeviceKit.Mutation(setting: .volume, value: 12))
        await Task.yield()

        #expect(model.selected == second)
        #expect(model.draft.volume == 72)
        #expect(connectionA.closeCount == 1)
    }

    @Test("A failed write is retried once and then enters an explicit error state")
    func writeRetryIsBounded() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(devices: [attached])
        let connection = FakeConnection(state: state(volume: 20))
        connection.submissionError = TestFailure.transport
        let model = DeviceModel(watcher: watcher) { _ in connection }

        try await waitUntil { model.phase == .ready }
        model.draft.volume = 50
        model.scheduleApply()
        try await waitUntil {
            if case .failed = model.phase { return true }
            return false
        }

        #expect(connection.submitted.count == 2)
        #expect(connection.submitted.allSatisfy {
            $0.setting == .volume && $0.value == 50
        })
    }

    @Test("A superseded slider value cannot retry over the latest value")
    func supersededWriteTimeoutIsIgnored() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(devices: [attached])
        let connection = FakeConnection(state: state(volume: 20))
        let model = DeviceModel(watcher: watcher) { _ in connection }

        try await waitUntil { model.phase == .ready }
        model.draft.volume = 21
        model.scheduleApply()
        try await waitUntil { connection.submitted.count == 1 }
        let superseded = DACDeviceKit.Mutation(setting: .volume, value: 21)

        model.draft.volume = 22
        model.scheduleApply()
        try await waitUntil { connection.submitted.count == 2 }
        connection.onDropped?(superseded)
        try await Task.sleep(for: .milliseconds(20))

        #expect(connection.submitted.count == 2)
        #expect(model.draft.volume == 22)
        #expect(model.phase == .ready)
    }

    @Test("A late confirmation cannot roll back a newer slider value")
    func lateConfirmationPreservesNewerDraft() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(devices: [attached])
        let connection = FakeConnection(state: state(volume: 20))
        let model = DeviceModel(watcher: watcher) { _ in connection }

        try await waitUntil { model.phase == .ready }
        model.draft.volume = 21
        model.scheduleApply()
        try await waitUntil { connection.submitted.count == 1 }

        model.draft.volume = 22
        model.scheduleApply()
        try await waitUntil { connection.submitted.count == 2 }

        connection.onConfirmed?(
            DACDeviceKit.Mutation(setting: .volume, value: 21))
        await Task.yield()

        #expect(model.draft.volume == 22)
        #expect(model.phase == .ready)

        connection.onConfirmed?(
            DACDeviceKit.Mutation(setting: .volume, value: 22))
        await Task.yield()

        #expect(model.confirmed.volume == 22)
        #expect(model.draft.volume == 22)
    }

    @Test("Enumeration order is stable and a new registry session reconnects")
    func selectionSurvivesReorderingAndReconnectsAfterReset() async throws {
        let first = device(location: 0x0110_0000, registry: 1)
        let second = device(location: 0x0210_0000, registry: 2)
        let resetFirst = device(location: first.locationID, registry: 99)
        let watcher = FakeWatcher(devices: [second, first])
        var connections: [UInt32: [FakeConnection]] = [
            first.locationID: [FakeConnection(state: state(volume: 10)),
                               FakeConnection(state: state(volume: 30))],
            second.locationID: [FakeConnection(state: state(volume: 20))],
        ]
        var opened: [UInt32] = []
        let model = DeviceModel(watcher: watcher) { device in
            opened.append(device.locationID)
            return connections[device.locationID]!.removeFirst()
        }

        try await waitUntil { model.phase == .ready }
        #expect(model.selected?.locationID == first.locationID)
        watcher.publish(Array([first, second].reversed()))
        await Task.yield()
        #expect(opened == [first.locationID])

        watcher.publish([resetFirst, second])
        try await waitUntil { model.draft.volume == 30 }
        #expect(opened == [first.locationID, first.locationID])
        #expect(model.selected?.registryEntryID == 99)
    }

    @Test("Changes to an unselected device do not disturb the active session")
    func unselectedDeviceChangesAreIgnored() async throws {
        let selected = device(location: 0x0110_0000, registry: 1)
        let other = device(location: 0x0210_0000, registry: 2)
        let resetOther = device(location: other.locationID, registry: 99)
        let watcher = FakeWatcher(devices: [selected])
        let connection = FakeConnection(state: state(volume: 31))
        var openCount = 0
        let model = DeviceModel(watcher: watcher) { device in
            #expect(device == selected)
            openCount += 1
            return connection
        }

        try await waitUntil { model.phase == .ready }
        watcher.publish([other, selected])
        await Task.yield()
        watcher.publish([selected])
        await Task.yield()
        watcher.publish([resetOther, selected])
        await Task.yield()

        #expect(model.selected == selected)
        #expect(model.devices == [selected, resetOther])
        #expect(model.draft.volume == 31)
        #expect(openCount == 1)
        #expect(connection.closeCount == 0)
    }

    @Test("Late ACK, timeout, and removal callbacks from the old device are ignored")
    func staleCallbacksCannotDisconnectNewSelection() async throws {
        let first = device(location: 0x0110_0000, registry: 1)
        let second = device(location: 0x0210_0000, registry: 2)
        let watcher = FakeWatcher(devices: [first])
        let connectionA = FakeConnection(state: state(volume: 20))
        let connectionB = FakeConnection(state: state(volume: 72))
        let model = DeviceModel(watcher: watcher) { device in
            device == first ? connectionA : connectionB
        }

        try await waitUntil { model.phase == .ready }
        watcher.publish([second, first])
        await Task.yield()
        model.select(second)
        try await waitUntil {
            model.phase == .ready && model.draft.volume == 72
        }

        let stale = DACDeviceKit.Mutation(setting: .volume, value: 99)
        connectionA.onConfirmed?(stale)
        connectionA.onDropped?(stale)
        connectionA.onRemoved?()
        await Task.yield()

        #expect(model.selected == second)
        #expect(model.phase == .ready)
        #expect(model.confirmed.volume == 72)
        #expect(model.draft.volume == 72)
        #expect(connectionA.closeCount == 1)
        #expect(connectionB.closeCount == 0)
    }

    @Test("A passive HID match event reconnects a reinserted device")
    func passiveMatchReconnectsDevice() async throws {
        let initial = device(location: 0x0110_0000, registry: 1)
        let reinserted = device(location: initial.locationID, registry: 2)
        let watcher = FakeWatcher(devices: [initial])
        let first = FakeConnection(state: state(volume: 20))
        let second = FakeConnection(state: state(volume: 42))
        var connections = [first, second]
        let model = DeviceModel(watcher: watcher) { _ in
            connections.removeFirst()
        }

        try await waitUntil { model.phase == .ready }
        watcher.publish([])
        try await waitUntil { model.phase == .disconnected }

        watcher.publish([reinserted])

        try await waitUntil {
            model.phase == .ready && model.draft.volume == 42
        }
        #expect(model.selected == reinserted)
        #expect(first.closeCount == 1)
        #expect(connections.isEmpty)
    }

    @Test("A transient readiness timeout is retried without showing an error")
    func transientReadinessTimeoutIsRetried() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(devices: [attached])
        let connection = FakeConnection()
        connection.readResults = [
            .failure(TestFailure.transport),
            .success(state(volume: 37)),
        ]
        let model = DeviceModel(watcher: watcher) { _ in connection }

        try await waitUntil(timeout: .seconds(2)) {
            model.phase == .ready && model.draft.volume == 37
        }
        #expect(connection.readCount == 2)
        #expect(model.phase == .ready)
    }

    @Test("Refresh reconciles device callbacks without retrying an older write")
    func refreshIsolatesOutstandingWrites() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(devices: [attached])
        let connection = FakeConnection(state: state(volume: 20))
        let model = DeviceModel(watcher: watcher) { _ in connection }

        try await waitUntil { model.phase == .ready }
        model.draft.volume = 21
        model.scheduleApply()
        try await waitUntil { connection.submitted.count == 1 }

        connection.immediateRead = nil
        model.refresh()
        try await waitUntil { model.phase == .reading && connection.readCount == 2 }

        let timedOut = DACDeviceKit.Mutation(setting: .volume, value: 21)
        connection.onDropped?(timedOut)
        connection.onChange?(DACDeviceKit.Mutation(setting: .volume, value: 22))
        await Task.yield()

        #expect(model.phase == .reading)
        #expect(connection.submitted.count == 1)

        connection.completeRead(state(volume: 20))
        try await waitUntil { model.phase == .ready }

        #expect(model.confirmed.volume == 22)
        #expect(model.draft.volume == 22)
        #expect(connection.submitted.count == 1)
    }

    @Test("A watcher startup failure can be retried without relaunching the app")
    func watcherFailureCanRecover() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(
            devices: [], startError: TestFailure.transport)
        let connection = FakeConnection(state: state(volume: 35))
        let model = DeviceModel(watcher: watcher) { _ in connection }

        guard case .failed = model.phase else {
            Issue.record("Watcher startup failure was not exposed")
            return
        }

        watcher.startError = nil
        watcher.devices = [attached]
        watcher.probeResult = .success([attached])
        model.refresh()

        try await waitUntil {
            model.phase == .ready && model.draft.volume == 35
        }
        #expect(watcher.startCount == 2)
        #expect(watcher.stopCount == 1)
        #expect(model.selected == attached)
    }

    @Test("A watcher failure during refresh remains visible until notifications restart")
    func runningWatcherFailureCanRecover() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(devices: [attached])
        let connection = FakeConnection(state: state(volume: 35))
        let model = DeviceModel(watcher: watcher) { _ in connection }

        try await waitUntil { model.phase == .ready }
        connection.immediateRead = nil
        model.refresh()
        try await waitUntil { model.phase == .reading && connection.readCount == 2 }

        watcher.onFailure?("notification failed")
        #expect(model.phase == .failed("notification failed"))
        connection.completeRead(state(volume: 99))
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.phase == .failed("notification failed"))
        #expect(model.draft.volume == 35)

        connection.immediateRead = state(volume: 42)
        model.refresh()

        try await waitUntil {
            model.phase == .ready && connection.readCount == 3
        }
        #expect(watcher.startCount == 2)
        #expect(watcher.stopCount == 1)
        #expect(model.selected == attached)
        #expect(model.draft.volume == 42)
    }

    @Test("The selected driver controls visible settings and validation")
    func driverCapabilitiesOwnTheModelSurface() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(devices: [attached])
        let volume = DACDeviceKit.SettingDescriptor(
            id: .volume,
            title: "音量",
            systemImage: "speaker.wave.2",
            group: .audio,
            presentation: .range(
                minimum: 0, maximum: 10, step: 1, format: .number))
        let descriptor = try DACDeviceKit.DriverDescriptor(
            settings: [volume],
            readback: .complete,
            confirmation: .acknowledgement,
            readRetryDelays: [],
            writeRetryLimit: 0)
        let connection = FakeConnection(
            state: state(volume: 5), descriptor: descriptor)
        let model = DeviceModel(watcher: watcher) { _ in connection }

        try await waitUntil { model.phase == .ready }
        #expect(model.settings.map(\.id) == [.volume])

        model.updateDraft(.volume, value: 11)
        await Task.yield()
        #expect(model.draft.volume == 5)
        #expect(connection.submitted.isEmpty)

        model.updateDraft(.volume, value: 7)
        try await waitUntil { connection.submitted.count == 1 }
        #expect(connection.submitted == [
            DACDeviceKit.Mutation(setting: .volume, value: 7)
        ])
    }

    @Test("An incomplete driver snapshot fails before the model becomes ready")
    func incompleteSnapshotFailsClosed() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(devices: [attached])
        let descriptor = try DACDeviceKit.DriverDescriptor(
            settings: Array(TestDevice.settings.prefix(2)),
            readback: .complete,
            confirmation: .acknowledgement,
            readRetryDelays: [],
            writeRetryLimit: 0)
        let connection = FakeConnection(
            state: DACDeviceKit.Snapshot(valid: true, values: [.volume: 5]),
            descriptor: descriptor)
        let model = DeviceModel(watcher: watcher) { _ in connection }

        try await waitUntil {
            if case .failed = model.phase { return true }
            return false
        }
        #expect(model.phase == .failed(
            DACDeviceKit.ConfigurationFailure.incompleteSnapshot(.gain)
                .localizedDescription))
        #expect(!model.isReady)
    }

    @Test("Shortcut volume steps use the selected driver's mutation path")
    func shortcutVolumeUsesSelectedDriver() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(devices: [attached])
        let connection = FakeConnection(state: state(volume: 20))
        let model = DeviceModel(watcher: watcher) { _ in connection }

        try await waitUntil { model.phase == .ready }
        #expect(model.adjustVolume(bySteps: 1))
        try await waitUntil { connection.submitted.count == 1 }

        #expect(model.draft.volume == 21)
        #expect(connection.submitted == [
            DACDeviceKit.Mutation(setting: .volume, value: 21)
        ])
    }

    @Test("Shortcut volume respects the selected driver's step and range")
    func shortcutVolumeRespectsDriverRange() async throws {
        let attached = device(location: 0x0110_0000, registry: 1)
        let watcher = FakeWatcher(devices: [attached])
        let volume = DACDeviceKit.SettingDescriptor(
            id: .volume,
            title: "音量",
            systemImage: "speaker.wave.2",
            group: .audio,
            presentation: .range(
                minimum: 0, maximum: 9, step: 2, format: .number))
        let descriptor = try DACDeviceKit.DriverDescriptor(
            settings: [volume],
            readback: .complete,
            confirmation: .acknowledgement,
            readRetryDelays: [],
            writeRetryLimit: 0)
        let connection = FakeConnection(
            state: state(volume: 6), descriptor: descriptor)
        let model = DeviceModel(watcher: watcher) { _ in connection }

        try await waitUntil { model.phase == .ready }
        #expect(model.adjustVolume(bySteps: 1))
        try await waitUntil { connection.submitted.count == 1 }
        #expect(model.draft.volume == 8)
        #expect(!model.adjustVolume(bySteps: 1))
        #expect(connection.submitted == [
            DACDeviceKit.Mutation(setting: .volume, value: 8)
        ])
    }

    @Test("Shortcut volume fails closed while the selected DAC is unavailable")
    func shortcutVolumeRequiresReadyDevice() async {
        let watcher = FakeWatcher(devices: [])
        let model = DeviceModel(watcher: watcher) { _ in
            Issue.record("A disconnected shortcut must not open a driver")
            return FakeConnection()
        }

        #expect(!model.adjustVolume(bySteps: 1))
        #expect(model.phase == .disconnected)
    }

    private func device(location: UInt32, registry: UInt64) -> AttachedDevice {
        AttachedDevice(
            profile: TestDevice.profile,
            productID: TestDevice.profile.hidMatches[0].productID,
            locationID: location,
            registryEntryID: registry,
            name: TestDevice.profile.displayName,
            portPath: "1-1")
    }

    private func state(volume: Int) -> DACDeviceKit.Snapshot {
        DACDeviceKit.Snapshot(
            valid: true,
            values: [
                .volume: volume,
                .gain: 0,
                .filter: 0,
                .balance: 0,
                .brightness: 5,
                .screenTimeout: 30,
                .orientation: 0,
                .screenOffset: 5,
            ],
            firmware: "01.00.00")
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for model state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
