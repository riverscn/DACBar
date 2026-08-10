import Foundation

public enum DACDeviceKit {}

extension DACDeviceKit {

    public struct SettingID: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let volume = SettingID(rawValue: "volume")
        public static let gain = SettingID(rawValue: "gain")
        public static let filter = SettingID(rawValue: "filter")
        public static let balance = SettingID(rawValue: "balance")
        public static let brightness = SettingID(rawValue: "brightness")
        public static let orientation = SettingID(rawValue: "orientation")
        public static let screenTimeout = SettingID(rawValue: "screen-timeout")
        public static let screenOffset = SettingID(rawValue: "screen-offset")
        public static let themeColor = SettingID(rawValue: "theme-color")
    }

    public struct SettingGroup: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let isCollapsible: Bool

        public init(id: String, title: String, isCollapsible: Bool = false) {
            self.id = id
            self.title = title
            self.isCollapsible = isCollapsible
        }

        public static let audio = SettingGroup(
            id: "audio",
            title: CoreL10n.text("settings.group.audio", defaultValue: "Audio"))
        public static let display = SettingGroup(
            id: "display",
            title: CoreL10n.text("settings.group.display", defaultValue: "Display"),
            isCollapsible: true)
    }

    public struct SettingOption: Identifiable, Hashable, Sendable {
        public let value: Int
        public let label: String
        public let note: String?

        public var id: Int { value }

        public init(value: Int, label: String, note: String? = nil) {
            self.value = value
            self.label = label
            self.note = note
        }
    }

    public enum ValueFormat: Hashable, Sendable {
        case number
        case balance
    }

    public enum SettingPresentation: Hashable, Sendable {
        case range(minimum: Int, maximum: Int, step: Int, format: ValueFormat)
        case segmented([SettingOption])
        case menu([SettingOption])
        case toggle
        case color
        case readOnly
    }

    public struct SettingDescriptor: Identifiable, Hashable, Sendable {
        public let id: SettingID
        public let title: String
        public let systemImage: String
        public let group: SettingGroup
        public let presentation: SettingPresentation
        public let explanation: String?

        public init(
            id: SettingID,
            title: String,
            systemImage: String,
            group: SettingGroup,
            presentation: SettingPresentation,
            explanation: String? = nil
        ) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.group = group
            self.presentation = presentation
            self.explanation = explanation
        }

        public var isWritable: Bool {
            if case .readOnly = presentation { return false }
            return true
        }

        public func validate(_ value: Int) throws {
            switch presentation {
            case .range(let minimum, let maximum, let step, _):
                guard minimum <= maximum, step > 0,
                      value >= minimum, value <= maximum else {
                    throw DriverFailure.invalidSetting(id, value)
                }
                let distance = value.subtractingReportingOverflow(minimum)
                guard !distance.overflow,
                      distance.partialValue.isMultiple(of: step)
                else { throw DriverFailure.invalidSetting(id, value) }
            case .segmented(let options), .menu(let options):
                guard options.contains(where: { $0.value == value }) else {
                    throw DriverFailure.invalidSetting(id, value)
                }
            case .toggle:
                guard value == 0 || value == 1 else {
                    throw DriverFailure.invalidSetting(id, value)
                }
            case .color:
                guard 0...0xFF_FFFF ~= value else {
                    throw DriverFailure.invalidSetting(id, value)
                }
            case .readOnly:
                throw DriverFailure.readOnlySetting(id)
            }
        }
    }

    /// Describes where the complete logical snapshot returned by `Driver.read`
    /// comes from. Drivers own partial-state merging and caching; DeviceModel
    /// deliberately receives the same complete Snapshot contract for every
    /// policy.
    public enum ReadbackPolicy: Hashable, Sendable {
        case complete
        case partial
        case writeOnlyCached
    }

    /// The device-specific boundary at which a Driver emits `onConfirmed`.
    /// DeviceModel does not interpret this value: every Driver translates its
    /// protocol into the common confirmed/dropped callback contract.
    public enum ConfirmationPolicy: Hashable, Sendable {
        case acknowledgement
        case readAfterWrite
        case transportCompletion
        case optimistic
    }

    public struct DriverDescriptor: Sendable {
        public let settings: [SettingDescriptor]
        public let readback: ReadbackPolicy
        public let confirmation: ConfirmationPolicy
        public let readRetryDelays: [Duration]
        public let writeRetryLimit: Int

        public init(
            settings: [SettingDescriptor],
            readback: ReadbackPolicy,
            confirmation: ConfirmationPolicy,
            readRetryDelays: [Duration],
            writeRetryLimit: Int
        ) throws {
            var settingIDs: Set<SettingID> = []
            var groups: [String: SettingGroup] = [:]
            for setting in settings {
                guard settingIDs.insert(setting.id).inserted else {
                    throw ConfigurationFailure.duplicateSettingID(setting.id)
                }
                let groupID = setting.group.id
                guard !groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigurationFailure.emptySettingGroupID(setting.id)
                }
                if let existing = groups[groupID], existing != setting.group {
                    throw ConfigurationFailure.conflictingSettingGroupID(groupID)
                }
                groups[groupID] = setting.group
                switch setting.presentation {
                case .range(let minimum, let maximum, let step, _):
                    let span = maximum.subtractingReportingOverflow(minimum)
                    guard minimum <= maximum, step > 0, !span.overflow else {
                        throw ConfigurationFailure.invalidRange(
                            setting.id, minimum: minimum, maximum: maximum, step: step)
                    }
                case .segmented(let options), .menu(let options):
                    guard !options.isEmpty else {
                        throw ConfigurationFailure.emptyOptions(setting.id)
                    }
                    var optionIDs: Set<Int> = []
                    for option in options where !optionIDs.insert(option.id).inserted {
                        throw ConfigurationFailure.duplicateOptionID(setting.id, option.id)
                    }
                case .toggle, .color, .readOnly:
                    break
                }
            }
            for (index, delay) in readRetryDelays.enumerated() where delay < .zero {
                throw ConfigurationFailure.negativeReadRetryDelay(index)
            }
            guard writeRetryLimit >= 0 else {
                throw ConfigurationFailure.negativeWriteRetryLimit(writeRetryLimit)
            }
            self.settings = settings
            self.readback = readback
            self.confirmation = confirmation
            self.readRetryDelays = readRetryDelays
            self.writeRetryLimit = writeRetryLimit
        }

        /// Enforces the common `Driver.read()` contract at the host boundary.
        /// Even partial/write-only transports must merge their state before
        /// returning a logical snapshot to the App.
        public func validate(_ snapshot: Snapshot) throws {
            guard snapshot.valid else { throw ConfigurationFailure.invalidSnapshot }
            for setting in settings {
                if let value = snapshot.values[setting.id] {
                    do {
                        if setting.isWritable { try setting.validate(value) }
                    } catch {
                        throw ConfigurationFailure.invalidSnapshotValue(setting.id, value)
                    }
                } else if setting.isWritable || snapshot.textValues[setting.id] == nil {
                    throw ConfigurationFailure.incompleteSnapshot(setting.id)
                }
            }
        }
    }

    public struct Mutation: Hashable, Sendable {
        public let setting: SettingID
        public let value: Int

        public init(setting: SettingID, value: Int) {
            self.setting = setting
            self.value = value
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public var valid: Bool
        public var values: [SettingID: Int]
        public var textValues: [SettingID: String]
        public var firmware: String

        public init(
            valid: Bool = false,
            values: [SettingID: Int] = [:],
            textValues: [SettingID: String] = [:],
            firmware: String = ""
        ) {
            self.valid = valid
            self.values = values
            self.textValues = textValues
            self.firmware = firmware
        }

        public subscript(setting: SettingID) -> Int? {
            get { values[setting] }
            set { values[setting] = newValue }
        }

        public mutating func apply(_ mutation: Mutation) {
            values[mutation.setting] = mutation.value
        }

        public func mutations(
            to target: Snapshot,
            settings: [SettingDescriptor]
        ) throws -> [Mutation] {
            try settings.compactMap { descriptor in
                guard descriptor.isWritable,
                      let oldValue = values[descriptor.id],
                      let newValue = target.values[descriptor.id],
                      oldValue != newValue
                else { return nil }
                try descriptor.validate(newValue)
                return Mutation(setting: descriptor.id, value: newValue)
            }
        }
    }

    public enum DriverFailure: Error, LocalizedError {
        case unsupportedModel(ModelID)
        case unsupportedSetting(SettingID)
        case invalidSetting(SettingID, Int)
        case readOnlySetting(SettingID)

        public var errorDescription: String? {
            switch self {
            case .unsupportedModel(let model):
                return CoreL10n.format(
                    "error.unsupported-model",
                    defaultValue: "No control driver is available for model %@.",
                    model.rawValue)
            case .unsupportedSetting(let setting):
                return CoreL10n.format(
                    "error.unsupported-setting",
                    defaultValue: "This device does not support %@.",
                    setting.rawValue)
            case .invalidSetting(let setting, let value):
                return CoreL10n.format(
                    "error.invalid-setting",
                    defaultValue: "The value %lld is outside the supported range for %@.",
                    Int64(value), setting.rawValue)
            case .readOnlySetting(let setting):
                return CoreL10n.format(
                    "error.read-only-setting",
                    defaultValue: "%@ is read-only.",
                    setting.rawValue)
            }
        }
    }

    @MainActor
    public protocol Driver: AnyObject {
        var profile: DeviceProfile { get }
        var descriptor: DriverDescriptor { get }
        /// A change initiated outside this app, such as a device button.
        var onChange: ((Mutation) -> Void)? { get set }
        /// Emitted when the descriptor's confirmation boundary is satisfied.
        var onConfirmed: ((Mutation) -> Void)? { get set }
        /// Emitted when a submitted mutation fails after `submit` returned.
        var onDropped: ((Mutation) -> Void)? { get set }
        var onRemoved: (() -> Void)? { get set }

        /// Returns a complete logical UI snapshot. Drivers with partial or
        /// write-only readback merge their protocol state/cache before return.
        func read() async throws -> Snapshot
        /// Validates and submits one mutation. Failures known before return are
        /// thrown; later confirmation failures are reported through onDropped.
        func submit(_ mutation: Mutation) async throws
        func close()
    }

    /// One independently compiled family of supported devices. The App owns
    /// composition; each plug-in owns discovery enumeration and driver creation
    /// for the profiles it publishes. Discovery is deliberately synchronous and
    /// main-actor-bound while every shipped backend is one bounded IOHID snapshot.
    /// A backend that waits, polls, or streams must introduce an asynchronous
    /// discovery abstraction rather than block this compatibility contract.
    @MainActor
    public protocol DevicePlugin {
        var profiles: [DeviceProfile] { get }
        func devices() throws -> [Device]
        func makeDriver(for device: Device) throws -> any Driver
    }

}

public extension DACDeviceKit.DevicePlugin {
    func supports(_ profile: DACDeviceKit.DeviceProfile) -> Bool {
        profiles.contains(profile)
    }
}
