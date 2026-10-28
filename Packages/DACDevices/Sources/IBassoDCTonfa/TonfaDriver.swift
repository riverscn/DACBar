import Foundation
import DACDeviceKit

extension IBassoDCTonfa {
    typealias Driver = DACDeviceKit.Driver
    typealias DriverDescriptor = DACDeviceKit.DriverDescriptor
    typealias Mutation = DACDeviceKit.Mutation
    typealias SettingDescriptor = DACDeviceKit.SettingDescriptor
    typealias SettingID = DACDeviceKit.SettingID
    typealias SettingOption = DACDeviceKit.SettingOption
    typealias Snapshot = DACDeviceKit.Snapshot

    @MainActor
    final class TonfaDriver: Driver {
        let profile: DeviceProfile
        let descriptor = TonfaDriver.driverDescriptor

        nonisolated static let driverDescriptor = try! DriverDescriptor(
            settings: TonfaDriver.settings,
            readback: .complete,
            confirmation: .transportCompletion,
            readRetryDelays: [.milliseconds(250), .milliseconds(500)],
            writeRetryLimit: 1)

        var onChange: ((Mutation) -> Void)?
        var onConfirmed: ((Mutation) -> Void)?
        var onDropped: ((Mutation) -> Void)?
        var onRemoved: (() -> Void)?

        private let connection: Connection

        init(device: Device) throws {
            profile = device.profile
            connection = try Connection(device: device)
            connection.onChange = { [weak self] in
                self?.onChange?(Self.mutation(from: $0))
            }
            connection.onConfirmed = { [weak self] in
                self?.onConfirmed?(Self.mutation(from: $0))
            }
            connection.onRemoved = { [weak self] in self?.onRemoved?() }
        }

        func read() async throws -> Snapshot {
            Self.snapshot(from: try await connection.read())
        }

        func submit(_ mutation: Mutation) async throws {
            guard let descriptor = descriptor.settings.first(where: {
                $0.id == mutation.setting
            }) else {
                throw DACDeviceKit.DriverFailure.unsupportedSetting(mutation.setting)
            }
            try descriptor.validate(mutation.value)
            try await connection.submit(try Self.setting(from: mutation))
        }

        func close() {
            connection.close()
        }

        nonisolated static func snapshot(from state: State) -> Snapshot {
            Snapshot(
                valid: state.valid,
                values: [
                    .volume: state.volume,
                    .filter: state.filter,
                    .gain: state.gain,
                    .balance: state.balance,
                    .coaxialOutput: state.coaxialOutput,
                    .keyControl: state.keyControl,
                    .screenTimeout: state.screenTimeout,
                    .orientation: state.orientation,
                ],
                textValues: [.uacVersion: "2.0"],
                firmware: state.firmware)
        }

        nonisolated static func mutation(from setting: Setting) -> Mutation {
            let id: SettingID
            switch setting {
            case .volume: id = .volume
            case .filter: id = .filter
            case .gain: id = .gain
            case .balance: id = .balance
            case .coaxialOutput: id = .coaxialOutput
            case .keyControl: id = .keyControl
            case .screenTimeout: id = .screenTimeout
            case .orientation: id = .orientation
            }
            return Mutation(setting: id, value: setting.value)
        }

        nonisolated static func setting(from mutation: Mutation) throws -> Setting {
            switch mutation.setting {
            case .volume: return .volume(mutation.value)
            case .filter: return .filter(mutation.value)
            case .gain: return .gain(mutation.value)
            case .balance: return .balance(mutation.value)
            case .coaxialOutput: return .coaxialOutput(mutation.value)
            case .keyControl: return .keyControl(mutation.value)
            case .screenTimeout: return .screenTimeout(mutation.value)
            case .orientation: return .orientation(mutation.value)
            default:
                throw DACDeviceKit.DriverFailure.unsupportedSetting(mutation.setting)
            }
        }

        nonisolated static let settings: [SettingDescriptor] = {
            let filters = [
                TonfaL10n.text(
                    "filter.phase-fast",
                    defaultValue: "Phase-compensated, fast roll-off"),
                TonfaL10n.text(
                    "filter.phase-slow",
                    defaultValue: "Phase-compensated, slow roll-off"),
                TonfaL10n.text(
                    "filter.latency-fast",
                    defaultValue: "Low latency, fast roll-off"),
                TonfaL10n.text(
                    "filter.latency-slow",
                    defaultValue: "Low latency, slow roll-off"),
                TonfaL10n.text("filter.nos", defaultValue: "Non-oversampling"),
            ].enumerated().map {
                SettingOption(value: $0.offset, label: $0.element)
            }
            return [
                SettingDescriptor(
                    id: .volume,
                    title: TonfaL10n.text("settings.volume", defaultValue: "Volume"),
                    systemImage: "speaker.wave.2", group: .audio,
                    presentation: .range(
                        minimum: 0, maximum: 100, step: 1, format: .number)),
                SettingDescriptor(
                    id: .gain,
                    title: TonfaL10n.text("settings.gain", defaultValue: "Gain"),
                    systemImage: "dial.high", group: .audio,
                    presentation: .options([
                        SettingOption(
                            value: 0,
                            label: TonfaL10n.text(
                                "settings.gain.low", defaultValue: "Low")),
                        SettingOption(
                            value: 1,
                            label: TonfaL10n.text(
                                "settings.gain.medium", defaultValue: "Medium")),
                        SettingOption(
                            value: 2,
                            label: TonfaL10n.text(
                                "settings.gain.high", defaultValue: "High")),
                    ])),
                SettingDescriptor(
                    id: .filter,
                    title: TonfaL10n.text("settings.filter", defaultValue: "Filter"),
                    systemImage: "waveform", group: .audio,
                    presentation: .options(filters)),
                SettingDescriptor(
                    id: .coaxialOutput,
                    title: TonfaL10n.text(
                        "settings.coaxial-output", defaultValue: "Coaxial output"),
                    systemImage: "cable.connector", group: .audio,
                    presentation: .toggle),
                SettingDescriptor(
                    id: .keyControl,
                    title: TonfaL10n.text(
                        "settings.key-control",
                        defaultValue: "Knob controls volume while screen is off"),
                    systemImage: "dial.medium", group: .audio,
                    presentation: .toggle),
                SettingDescriptor(
                    id: .balance,
                    title: TonfaL10n.text("settings.balance", defaultValue: "Balance"),
                    systemImage: "arrow.left.and.right", group: .audio,
                    presentation: .range(
                        minimum: -10, maximum: 10, step: 1, format: .balance)),
                SettingDescriptor(
                    id: .uacVersion,
                    title: TonfaL10n.text(
                        "settings.uac-version", defaultValue: "UAC version"),
                    systemImage: "waveform.badge.magnifyingglass", group: .audio,
                    presentation: .readOnly),
                SettingDescriptor(
                    id: .screenTimeout,
                    title: TonfaL10n.text(
                        "settings.screen-timeout", defaultValue: "Screen timeout"),
                    systemImage: "clock", group: .display,
                    presentation: .options([
                        SettingOption(
                            value: 0,
                            label: TonfaL10n.text(
                                "settings.screen-timeout.10", defaultValue: "10 sec")),
                        SettingOption(
                            value: 1,
                            label: TonfaL10n.text(
                                "settings.screen-timeout.20", defaultValue: "20 sec")),
                        SettingOption(
                            value: 2,
                            label: TonfaL10n.text(
                                "settings.screen-timeout.30", defaultValue: "30 sec")),
                        SettingOption(
                            value: 3,
                            label: TonfaL10n.text(
                                "settings.screen-timeout.always", defaultValue: "Always on")),
                    ])),
                SettingDescriptor(
                    id: .orientation,
                    title: TonfaL10n.text(
                        "settings.orientation", defaultValue: "Orientation"),
                    systemImage: "arrow.clockwise", group: .display,
                    presentation: .options([
                        SettingOption(value: 0, label: "0°"),
                        SettingOption(value: 1, label: "180°"),
                    ])),
            ]
        }()
    }
}
