import AppKit
import Foundation

struct HotKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let command = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var result: Self = []
        if eventFlags.contains(.command) { result.insert(.command) }
        if eventFlags.contains(.control) { result.insert(.control) }
        if eventFlags.contains(.option) { result.insert(.option) }
        if eventFlags.contains(.shift) { result.insert(.shift) }
        self = result
    }

    var symbolPrefix: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

struct HotKeyShortcut: Codable, Equatable, Sendable {
    // Hardware key codes make the shortcut stable when the active keyboard
    // layout changes. keyLabel is presentation metadata captured alongside it.
    let keyCode: UInt32
    let modifiers: HotKeyModifiers
    let keyLabel: String

    static let defaultVolumeUp = Self(
        keyCode: 126, modifiers: [.control, .command], keyLabel: "↑")
    static let defaultVolumeDown = Self(
        keyCode: 125, modifiers: [.control, .command], keyLabel: "↓")

    var displayName: String { modifiers.symbolPrefix + keyLabel }

    /// Requiring two modifiers avoids hijacking ordinary typing and the most
    /// common one-modifier application shortcuts. Command or Control is also
    /// required so Option+Shift text-entry combinations are never registered.
    var isValid: Bool {
        let modifierCount = modifiers.rawValue.nonzeroBitCount
        return !keyLabel.isEmpty
            && modifierCount >= 2
            && (!modifiers.intersection([.command, .control]).isEmpty)
    }

    @MainActor
    init?(event: NSEvent) {
        let modifiers = HotKeyModifiers(eventFlags: event.modifierFlags)
        let label = Self.label(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers)
        let shortcut = Self(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyLabel: label)
        guard shortcut.isValid else { return nil }
        self = shortcut
    }

    init(keyCode: UInt32, modifiers: HotKeyModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    private static func label(keyCode: UInt16, characters: String?) -> String {
        let fixedLabels: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "␠", 51: "⌫",
            53: "⎋", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            103: "F11", 105: "F13", 106: "F16", 107: "F14",
            109: "F10", 111: "F12", 113: "F15", 118: "F4",
            120: "F2", 122: "F1", 123: "←", 124: "→",
            125: "↓", 126: "↑",
        ]
        if let fixed = fixedLabels[keyCode] { return fixed }
        guard let characters, !characters.isEmpty else {
            return "Key \(keyCode)"
        }
        return characters.uppercased(with: .current)
    }
}

enum AppPreferenceKey {
    static let hotKeysEnabled = "globalHotKeysEnabled"
    static let volumeUpShortcut = "volumeUpShortcut"
    static let volumeDownShortcut = "volumeDownShortcut"
}
