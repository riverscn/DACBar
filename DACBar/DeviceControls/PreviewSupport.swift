import DACDeviceKit
import Foundation
import IBassoDCTonfa
import SwiftUI

private typealias SettingDescriptor = DACDeviceKit.SettingDescriptor
private typealias SettingID = DACDeviceKit.SettingID
private typealias SettingOption = DACDeviceKit.SettingOption

/// Hardware-free stand-ins for the device layer, so the `#Preview` blocks
/// next to each view can run without a dongle.
///
/// The panel is capability-driven: it renders whatever `SettingDescriptor`s a
/// driver publishes. That means a model can be inspected without owning it —
/// a fixture descriptor list and an in-memory driver are all the UI ever sees
/// of real hardware. The second fixture exists to prove exactly that: it
/// exercises every presentation the renderer supports, with content that has
/// nothing in common with the Shanling list, through the same rows.
@MainActor
enum PreviewDevices {

    struct Fixture {
        let profile: DACDeviceKit.DeviceProfile
        let settings: [DACDeviceKit.SettingDescriptor]
        let snapshot: DACDeviceKit.Snapshot

        var attached: AttachedDevice {
            AttachedDevice(
                profile: profile,
                productID: profile.hidMatches.first?.productID ?? 0,
                locationID: 0x0120_0000,
                registryEntryID: 0x4242,
                name: profile.displayName,
                portPath: "1-2")
        }
    }

    /// The shipping model, with its real descriptors.
    static let shanlingUA1II = Fixture(
        profile: SupportedDevices.previewProfile,
        settings: SupportedDevices.previewSettings,
        snapshot: snapshot(
            for: SupportedDevices.previewSettings,
            firmware: "1.3",
            overrides: [.volume: 64, .gain: 1, .filter: 2, .balance: -3]))

    /// The other shipping model, with its real descriptors.
    static let tonfa = Fixture(
        profile: IBassoDCTonfa.Plugin().profiles[0],
        settings: IBassoDCTonfa.Plugin.previewSettings,
        snapshot: snapshot(
            for: IBassoDCTonfa.Plugin.previewSettings,
            firmware: "3.14.39",
            text: [SettingID(rawValue: "uac-version"): "2.0"]))

    /// A fictional second model. Different vendor, different capabilities, no
    /// styling of its own.
    static let secondModel = Fixture(
        profile: secondModelProfile,
        settings: secondModelSettings,
        snapshot: snapshot(
            for: secondModelSettings,
            firmware: "0.9.2",
            overrides: [
                SettingID.volume: 42,
                SettingID.gain: 1,
                SettingID.filter: 1,
                SettingID(rawValue: "output-mode"): 1,
                SettingID(rawValue: "line-out"): 0,
                SettingID.themeColor: 0x4C_8DFF,
            ],
            text: [SettingID(rawValue: "sample-rate"): "384 kHz · 32-bit"]))

    // MARK: - Second model capabilities

    private static let secondModelProfile = DACDeviceKit.DeviceProfile(
        id: DACDeviceKit.ModelID(rawValue: "preview.second-model"),
        displayName: "Preview DAC II",
        productNames: ["Preview DAC II"],
        hidMatches: [
            DACDeviceKit.HIDMatch(
                vendorID: 0x0001,
                productID: 0x0002,
                usagePage: 0xFF00,
                usage: 0x0001,
                inputReportSize: 16,
                outputReportSize: 16)
        ],
        discoveryKind: .hidService,
        transportKind: .hidReports,
        driverID: DACDeviceKit.DriverID(rawValue: "preview.second-model.driver"),
        verification: .experimental)

    private static let secondModelSettings: [DACDeviceKit.SettingDescriptor] = [
        SettingDescriptor(
            id: .volume,
            title: "Volume",
            systemImage: "speaker.wave.2",
            group: .audio,
            presentation: .range(minimum: 0, maximum: 60, step: 1, format: .number)),
        SettingDescriptor(
            id: .gain,
            title: "Gain mode",
            systemImage: "dial.high",
            group: .audio,
            presentation: .options([
                SettingOption(value: 0, label: "Low"),
                SettingOption(value: 1, label: "Mid"),
                SettingOption(value: 2, label: "High"),
            ])),
        SettingDescriptor(
            id: .filter,
            title: "Digital filter",
            systemImage: "waveform",
            group: .audio,
            presentation: .options([
                SettingOption(value: 0, label: "Sharp", note: "Steepest roll-off."),
                SettingOption(value: 1, label: "Slow", note: "Gentler, less pre-ringing."),
                SettingOption(value: 2, label: "NOS", note: "No oversampling."),
            ]),
            explanation: "Reconstruction filter applied after the DAC stage."),
        SettingDescriptor(
            id: SettingID(rawValue: "output-mode"),
            title: "Output",
            systemImage: "cable.connector",
            group: .audio,
            presentation: .options([
                SettingOption(value: 0, label: "3.5 mm"),
                SettingOption(value: 1, label: "4.4 mm"),
            ])),
        SettingDescriptor(
            id: SettingID(rawValue: "line-out"),
            title: "Line-out mode",
            systemImage: "powerplug",
            group: .audio,
            presentation: .toggle),
        SettingDescriptor(
            id: SettingID(rawValue: "sample-rate"),
            title: "Sample rate",
            systemImage: "gauge.with.dots.needle.33percent",
            group: .audio,
            presentation: .readOnly),
        SettingDescriptor(
            id: .brightness,
            title: "Brightness",
            systemImage: "sun.max",
            group: .display,
            presentation: .range(minimum: 0, maximum: 5, step: 1, format: .number)),
        SettingDescriptor(
            id: .themeColor,
            title: "Indicator colour",
            systemImage: "paintpalette",
            group: .display,
            presentation: .color),
    ]

    // MARK: - Snapshots

    static func snapshot(
        for settings: [DACDeviceKit.SettingDescriptor],
        firmware: String,
        overrides: [DACDeviceKit.SettingID: Int] = [:],
        text: [DACDeviceKit.SettingID: String] = [:]
    ) -> DACDeviceKit.Snapshot {
        var snapshot = DACDeviceKit.Snapshot(valid: true, firmware: firmware)
        for setting in settings {
            if let value = overrides[setting.id] ?? defaultValue(for: setting) {
                snapshot[setting.id] = value
            }
            if let displayed = text[setting.id] {
                snapshot.textValues[setting.id] = displayed
            }
        }
        return snapshot
    }

    private static func defaultValue(
        for setting: DACDeviceKit.SettingDescriptor
    ) -> Int? {
        switch setting.presentation {
        case .range(let minimum, let maximum, let step, _):
            return minimum + step * (((maximum - minimum) / step) / 2)
        case .options(let options):
            return options.first?.value
        case .toggle:
            return 0
        case .color:
            return 0x4C_8DFF
        case .readOnly:
            return nil
        }
    }
}

// MARK: - Stand-ins for the hardware layer

private enum PreviewFailure: LocalizedError {
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .transport(let message): return message
        }
    }
}

/// Serves a fixture snapshot and accepts writes in memory, so sliders and
/// pickers behave in a preview the way they do against a dongle.
@MainActor
final class PreviewDriver: DACDeviceKit.Driver {
    enum Behavior {
        /// Answers the first read immediately.
        case ready
        /// Never answers, which pins the panel in its reading state.
        case stalled
        case failing(String)
    }

    let profile: DACDeviceKit.DeviceProfile
    let descriptor: DACDeviceKit.DriverDescriptor
    var onChange: ((DACDeviceKit.Mutation) -> Void)?
    var onConfirmed: ((DACDeviceKit.Mutation) -> Void)?
    var onDropped: ((DACDeviceKit.Mutation) -> Void)?
    var onRemoved: (() -> Void)?

    private var snapshot: DACDeviceKit.Snapshot
    private let behavior: Behavior

    init(fixture: PreviewDevices.Fixture, behavior: Behavior = .ready) throws {
        profile = fixture.profile
        snapshot = fixture.snapshot
        self.behavior = behavior
        descriptor = try DACDeviceKit.DriverDescriptor(
            settings: fixture.settings,
            readback: .complete,
            confirmation: .optimistic,
            readRetryDelays: [],
            writeRetryLimit: 0)
    }

    func read() async throws -> DACDeviceKit.Snapshot {
        switch behavior {
        case .ready:
            return snapshot
        case .stalled:
            // Long enough that the preview stays on the reading state for as
            // long as anyone looks at it.
            try await Task.sleep(for: .seconds(86_400))
            return snapshot
        case .failing(let message):
            throw PreviewFailure.transport(message)
        }
    }

    func submit(_ mutation: DACDeviceKit.Mutation) async throws {
        snapshot.apply(mutation)
        onConfirmed?(mutation)
    }

    func close() {}
}

@MainActor
final class PreviewWatcher: DeviceWatching {
    var devices: [AttachedDevice]
    var onChange: (([AttachedDevice]) -> Void)?
    var onFailure: ((String) -> Void)?

    init(devices: [AttachedDevice]) {
        self.devices = devices
    }

    func start() throws {}
    func stop() {}
    func probe() throws -> [AttachedDevice] { devices }
}

@MainActor
extension DeviceModel {
    /// A model wired to in-memory hardware. Each call gets its own defaults
    /// suite so a preview never reads or writes the real selection.
    static func preview(
        fixtures: [PreviewDevices.Fixture],
        behavior: PreviewDriver.Behavior = .ready
    ) -> DeviceModel {
        let defaults = UserDefaults(suiteName: "preview.\(UUID().uuidString)")!
        return DeviceModel(
            selectionStore: DeviceSelectionStore(defaults: defaults),
            watcher: PreviewWatcher(devices: fixtures.map(\.attached)),
            driverFactory: { attached in
                guard let fixture = fixtures.first(where: {
                    $0.profile.id == attached.profile.id
                }) else {
                    throw DACDeviceKit.DriverFailure.unsupportedModel(attached.profile.id)
                }
                return try PreviewDriver(fixture: fixture, behavior: behavior)
            })
    }
}
