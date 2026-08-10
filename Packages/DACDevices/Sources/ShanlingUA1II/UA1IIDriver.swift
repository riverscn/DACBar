import Foundation
import DACDeviceKit

extension ShanlingUA1II {

    typealias Driver = DACDeviceKit.Driver
    typealias DriverDescriptor = DACDeviceKit.DriverDescriptor
    typealias DriverFailure = DACDeviceKit.DriverFailure
    typealias Mutation = DACDeviceKit.Mutation
    typealias SettingDescriptor = DACDeviceKit.SettingDescriptor
    typealias SettingID = DACDeviceKit.SettingID
    typealias SettingOption = DACDeviceKit.SettingOption
    typealias Snapshot = DACDeviceKit.Snapshot

    /// Semantic UA1 II driver. The existing HID connection remains the
    /// hardware-tested transport/protocol implementation; this adapter keeps
    /// UA1 II wire details out of the app model and UI.
    @MainActor
    final class UA1IIDriver: Driver {
        let profile: DeviceProfile
        let descriptor = UA1IIDriver.driverDescriptor

        nonisolated static let driverDescriptor = try! DriverDescriptor(
            settings: UA1IIDriver.settings,
            readback: .complete,
            confirmation: .acknowledgement,
            readRetryDelays: [.milliseconds(600), .seconds(1)],
            writeRetryLimit: 1)

        var onChange: ((Mutation) -> Void)?
        var onConfirmed: ((Mutation) -> Void)?
        var onDropped: ((Mutation) -> Void)?
        var onRemoved: (() -> Void)?

        private let connection: Connection

        init(device: Device) throws {
            self.profile = device.profile
            self.connection = try Connection(device: device)
            bindConnection()
        }

        func read() async throws -> Snapshot {
            Self.snapshot(from: try await connection.read())
        }

        func submit(_ mutation: Mutation) async throws {
            guard let setting = descriptor.settings.first(where: { $0.id == mutation.setting })
            else { throw DriverFailure.unsupportedSetting(mutation.setting) }
            try setting.validate(mutation.value)
            try await connection.submit(try Self.write(from: mutation))
        }

        func close() {
            connection.close()
        }

        private func bindConnection() {
            connection.onChange = { [weak self] write in
                self?.onChange?(Self.mutation(from: write))
            }
            connection.onConfirmed = { [weak self] write in
                self?.onConfirmed?(Self.mutation(from: write))
            }
            connection.onDropped = { [weak self] write in
                self?.onDropped?(Self.mutation(from: write))
            }
            connection.onRemoved = { [weak self] in
                self?.onRemoved?()
            }
        }

        nonisolated static func snapshot(from state: State) -> Snapshot {
            Snapshot(
                valid: state.valid,
                values: [
                    .volume: state.volume,
                    .gain: state.gain,
                    .filter: state.filter,
                    .balance: state.balance,
                    .brightness: state.brightness,
                    .orientation: state.orientation,
                    .screenTimeout: state.screenTimeout,
                    .screenOffset: state.screenOffset,
                ],
                firmware: state.firmware)
        }

        nonisolated static func mutation(from write: Write) -> Mutation {
            let value: Int
            let setting: SettingID
            switch write.command {
            case .volume:        (setting, value) = (.volume, Int(write.value))
            case .gain:          (setting, value) = (.gain, Int(write.value))
            case .filter:        (setting, value) = (.filter, Int(write.value))
            case .balance:
                (setting, value) = (.balance, Int(Int8(bitPattern: write.value)))
            case .brightness:    (setting, value) = (.brightness, Int(write.value))
            case .orientation:   (setting, value) = (.orientation, Int(write.value))
            case .screenTimeout: (setting, value) = (.screenTimeout, Int(write.value))
            case .screenOffset:
                (setting, value) = (.screenOffset, Int(write.value) - screenOffsetBias)
            }
            return Mutation(setting: setting, value: value)
        }

        nonisolated static func write(from mutation: Mutation) throws -> Write {
            let command: Command
            let wireValue: UInt8
            switch mutation.setting {
            case .volume:
                command = .volume
                wireValue = try unsigned(mutation)
            case .gain:
                command = .gain
                wireValue = try unsigned(mutation)
            case .filter:
                command = .filter
                wireValue = try unsigned(mutation)
            case .balance:
                command = .balance
                guard let signed = Int8(exactly: mutation.value) else {
                    throw DriverFailure.invalidSetting(mutation.setting, mutation.value)
                }
                wireValue = UInt8(bitPattern: signed)
            case .brightness:
                command = .brightness
                wireValue = try unsigned(mutation)
            case .orientation:
                command = .orientation
                wireValue = try unsigned(mutation)
            case .screenTimeout:
                command = .screenTimeout
                wireValue = try unsigned(mutation)
            case .screenOffset:
                command = .screenOffset
                guard let biased = UInt8(exactly: mutation.value + screenOffsetBias) else {
                    throw DriverFailure.invalidSetting(mutation.setting, mutation.value)
                }
                wireValue = biased
            default:
                throw DriverFailure.unsupportedSetting(mutation.setting)
            }
            return try Write(command, wireValue)
        }

        nonisolated private static func unsigned(_ mutation: Mutation) throws -> UInt8 {
            guard let value = UInt8(exactly: mutation.value) else {
                throw DriverFailure.invalidSetting(mutation.setting, mutation.value)
            }
            return value
        }

        nonisolated static let settings: [SettingDescriptor] = {
            let filterNames = [
                DeviceL10n.text("filter.linear-fast", defaultValue: "Linear phase, fast roll-off"),
                DeviceL10n.text("filter.linear-slow", defaultValue: "Linear phase, slow roll-off"),
                DeviceL10n.text("filter.minimum-fast", defaultValue: "Minimum phase, fast roll-off"),
                DeviceL10n.text("filter.minimum-slow", defaultValue: "Minimum phase, slow roll-off"),
                DeviceL10n.text("filter.nos", defaultValue: "Non-oversampling / bypass"),
            ]
            let filterNotes = [
                DeviceL10n.text("filter.linear-fast.note", defaultValue: "The most neutral option and the strongest suppression of digital artifacts. Transients can have very slight ringing before and after them. This is the usual default."),
                DeviceL10n.text("filter.linear-slow.note", defaultValue: "Slightly softer treble, with less ringing and a small loss at the top of the audible range."),
                DeviceL10n.text("filter.minimum-fast.note", defaultValue: "Sharper transients. Ringing occurs only after the transient, as it does with acoustic instruments."),
                DeviceL10n.text("filter.minimum-slow.note", defaultValue: "The most relaxed and softest treble, with the least ringing and the greatest high-frequency loss."),
                DeviceL10n.text("filter.nos.note", defaultValue: "Noticeably warmer and more analog-like. It skips digital filtering, rolling off more treble while leaving more digital artifacts."),
            ]
            let filterOptions = zip(filterNames, filterNotes).enumerated().map {
                SettingOption(value: $0.offset, label: $0.element.0, note: $0.element.1)
            }
            let filterExplanation = DeviceL10n.text(
                "filter.explanation",
                defaultValue: "Digital audio is a series of discrete samples. This filter controls how the signal is reconstructed between them and removes ultrasonic imaging.\n\nEach option trades cleaner filtering against preserving transient shape. The first four are subtle; non-oversampling is usually the only clearly audible choice.")
            return [
                SettingDescriptor(
                    id: .volume,
                    title: DeviceL10n.text("settings.volume", defaultValue: "Volume"),
                    systemImage: "speaker.wave.2",
                    group: .audio,
                    presentation: .range(minimum: 0, maximum: 99, step: 1, format: .number)),
                SettingDescriptor(
                    id: .gain,
                    title: DeviceL10n.text("settings.gain", defaultValue: "Gain"),
                    systemImage: "dial.high", group: .audio,
                    presentation: .segmented([
                        SettingOption(value: 0, label: DeviceL10n.text("settings.gain.low", defaultValue: "Low")),
                        SettingOption(value: 1, label: DeviceL10n.text("settings.gain.high", defaultValue: "High")),
                    ])),
                SettingDescriptor(
                    id: .filter,
                    title: DeviceL10n.text("settings.filter", defaultValue: "Filter"),
                    systemImage: "waveform", group: .audio,
                    presentation: .menu(filterOptions), explanation: filterExplanation),
                SettingDescriptor(
                    id: .balance,
                    title: DeviceL10n.text("settings.balance", defaultValue: "Balance"),
                    systemImage: "arrow.left.and.right",
                    group: .audio,
                    presentation: .range(minimum: -12, maximum: 12, step: 1, format: .balance)),
                SettingDescriptor(
                    id: .brightness,
                    title: DeviceL10n.text("settings.brightness", defaultValue: "Brightness"),
                    systemImage: "sun.max", group: .display,
                    presentation: .range(minimum: 0, maximum: 10, step: 1, format: .number)),
                SettingDescriptor(
                    id: .orientation,
                    title: DeviceL10n.text("settings.orientation", defaultValue: "Orientation"),
                    systemImage: "arrow.clockwise",
                    group: .display,
                    presentation: .segmented(
                        ["0°", "90°", "180°", "270°"].enumerated().map {
                            SettingOption(value: $0.offset, label: $0.element)
                        })),
                SettingDescriptor(
                    id: .screenTimeout,
                    title: DeviceL10n.text("settings.screen-timeout", defaultValue: "Screen timeout"),
                    systemImage: "clock", group: .display,
                    presentation: .menu(
                        [0, 10, 20, 30, 40, 50, 60].map {
                            SettingOption(
                                value: $0,
                                label: $0 == 0
                                    ? DeviceL10n.text("settings.screen-timeout.never", defaultValue: "Always on")
                                    : DeviceL10n.format("settings.screen-timeout.seconds", defaultValue: "%lld sec", Int64($0)))
                        })),
                SettingDescriptor(
                    id: .screenOffset,
                    title: DeviceL10n.text("settings.screen-offset", defaultValue: "Screen offset"),
                    systemImage: "arrow.up.and.down",
                    group: .display,
                    presentation: .range(minimum: 0, maximum: 10, step: 1, format: .number)),
            ]
        }()
    }
}
