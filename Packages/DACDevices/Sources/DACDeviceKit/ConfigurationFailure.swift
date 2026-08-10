import Foundation

extension DACDeviceKit {

    /// Errors produced while composing device plug-ins and driver metadata.
    /// These are programmer/configuration failures, not hardware I/O failures.
    public enum ConfigurationFailure: Error, Equatable, LocalizedError {
        case emptyModelID
        case emptyDriverID
        case duplicateModelID(ModelID)
        case duplicateDriverID(DriverID)
        case missingHIDMatch(ModelID)
        case invalidHIDMatch(HIDMatch)
        case duplicateHIDMatch(ModelID, HIDMatch)
        case conflictingHIDMatch(HIDMatch, [ModelID])
        case duplicateSettingID(SettingID)
        case duplicateOptionID(SettingID, Int)
        case emptyOptions(SettingID)
        case invalidRange(SettingID, minimum: Int, maximum: Int, step: Int)
        case negativeReadRetryDelay(Int)
        case negativeWriteRetryLimit(Int)
        case invalidSnapshot
        case incompleteSnapshot(SettingID)
        case invalidSnapshotValue(SettingID, Int)

        public var errorDescription: String? {
            switch self {
            case .emptyModelID:
                return "A device model ID cannot be empty."
            case .emptyDriverID:
                return "A device driver ID cannot be empty."
            case .duplicateModelID(let id):
                return "Device model ID \(id.rawValue) is registered more than once."
            case .duplicateDriverID(let id):
                return "Device driver ID \(id.rawValue) is registered more than once."
            case .missingHIDMatch(let id):
                return "HID-discovered model \(id.rawValue) has no HID signature."
            case .invalidHIDMatch:
                return "A HID match contains an invalid identifier or report size."
            case .duplicateHIDMatch(let model, _):
                return "Device model \(model.rawValue) repeats the same HID signature."
            case .conflictingHIDMatch(_, let models):
                return "A HID signature cannot be disambiguated between: "
                    + models.map(\.rawValue).joined(separator: ", ") + "."
            case .duplicateSettingID(let id):
                return "Setting ID \(id.rawValue) is declared more than once."
            case .duplicateOptionID(let setting, let value):
                return "Setting \(setting.rawValue) repeats option value \(value)."
            case .emptyOptions(let setting):
                return "Setting \(setting.rawValue) must declare at least one option."
            case .invalidRange(let setting, let minimum, let maximum, let step):
                return "Setting \(setting.rawValue) has invalid range \(minimum)...\(maximum) step \(step)."
            case .negativeReadRetryDelay(let index):
                return "Read retry delay at index \(index) cannot be negative."
            case .negativeWriteRetryLimit(let limit):
                return "Write retry limit \(limit) cannot be negative."
            case .invalidSnapshot:
                return "A driver read returned an invalid snapshot."
            case .incompleteSnapshot(let setting):
                return "A driver snapshot is missing \(setting.rawValue)."
            case .invalidSnapshotValue(let setting, let value):
                return "A driver snapshot contains invalid value \(value) for \(setting.rawValue)."
            }
        }
    }
}
