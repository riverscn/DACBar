import Foundation
import Testing
@testable import DACBar
@testable import DACDeviceKit
import ShanlingUA1II

@MainActor
private final class SelectedHardwareWatcher: DeviceWatching {
    let devices: [AttachedDevice]
    var onChange: (([AttachedDevice]) -> Void)?
    var onFailure: ((String) -> Void)?

    init(device: AttachedDevice) {
        devices = [device]
    }

    func start() throws {}
    func stop() {}
    func probe() throws -> [AttachedDevice] { devices }
}

@Suite("Device model hardware integration", .serialized)
@MainActor
struct HardwareDeviceModelTests {

    @Test(
        "Rapid UI changes converge without entering the retry error state",
        .enabled(if: ProcessInfo.processInfo.environment["DACBAR_HARDWARE_TESTS"] == "1")
    )
    func rapidChangesConverge() async throws {
        try await Task.sleep(for: .milliseconds(200))
        let target = try hardwareTarget()
        let watcher = SelectedHardwareWatcher(device: target)
        let model = DeviceModel(
            selectionStore: isolatedSelectionStore(),
            watcher: watcher
        ) { device in
            try ShanlingUA1II.Plugin().makeDriver(for: device.device)
        }
        try await waitUntil(timeout: .seconds(3)) { model.phase == .ready }

        let original = model.draft.brightness
        let alternate = original == 10 ? 9 : original + 1
        for _ in 0..<3 {
            // Exercise a sustained drag: SwiftUI produces updates much faster
            // than the transport, while DeviceModel keeps the latest target.
            for index in 0...60 {
                let value = index.isMultiple(of: 2) ? alternate : original
                _ = model.update(.brightness, to: value)
                try await Task.sleep(for: .milliseconds(20))
            }

            try await waitUntil(timeout: .seconds(3)) {
                model.phase == .ready && model.confirmed.brightness == alternate
            }
            #expect(model.phase == .ready)
            #expect(model.confirmed.brightness == alternate)

            #expect(model.update(.brightness, to: original))
            try await waitUntil(timeout: .seconds(3)) {
                model.phase == .ready && model.confirmed.brightness == original
            }
            #expect(model.phase == .ready)
            #expect(model.confirmed.brightness == original)
        }
    }

    private func isolatedSelectionStore() -> DeviceSelectionStore {
        let suiteName = "DACBarTests.HardwareDeviceModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return DeviceSelectionStore(defaults: defaults)
    }

    private func hardwareTarget() throws -> AttachedDevice {
        let devices = try ShanlingUA1II.Plugin().devices()
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["DACBAR_HARDWARE_LOCATION_ID"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let locationID: UInt32?
            if trimmed.lowercased().hasPrefix("0x") {
                locationID = UInt32(trimmed.dropFirst(2), radix: 16)
            } else {
                locationID = UInt32(trimmed, radix: 10)
            }
            guard let locationID,
                  let target = devices.first(where: { $0.locationID == locationID })
            else {
                throw HardwareDeviceModelConfigurationFailure.invalidTarget(raw)
            }
            return AttachedDevice(target)
        }
        guard let only = devices.first else {
            throw HardwareDeviceModelConfigurationFailure.noDevice
        }
        guard devices.count == 1 else {
            throw HardwareDeviceModelConfigurationFailure.ambiguous(
                devices.map(\.locationID))
        }
        return AttachedDevice(only)
    }

    private func waitUntil(
        timeout: Duration,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !condition() {
            Issue.record("Timed out waiting for the hardware-backed device model")
        }
    }
}

private enum HardwareDeviceModelConfigurationFailure: Error, LocalizedError {
    case noDevice
    case ambiguous([UInt32])
    case invalidTarget(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "没有检测到受支持的真机"
        case .ambiguous(let locations):
            let values = locations.map {
                "0x" + String($0, radix: 16, uppercase: true)
            }.joined(separator: ", ")
            return "检测到多台设备（\(values)）；请设置 DACBAR_HARDWARE_LOCATION_ID"
        case .invalidTarget(let raw):
            return "找不到 DACBAR_HARDWARE_LOCATION_ID=\(raw) 对应的设备"
        }
    }
}
