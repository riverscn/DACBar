import Foundation

enum DeviceL10n {
    static func text(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }

    static func format(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        _ arguments: any CVarArg...
    ) -> String {
        String(
            format: text(key, defaultValue: defaultValue),
            locale: .current,
            arguments: arguments)
    }
}
