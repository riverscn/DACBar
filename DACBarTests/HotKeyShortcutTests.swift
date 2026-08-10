import Foundation
import Testing
@testable import DACBar

@Suite("Global hot-key preferences")
struct HotKeyShortcutTests {
    @Test("Defaults are safe two-modifier shortcuts")
    func defaultsAreValid() {
        #expect(HotKeyShortcut.defaultVolumeUp.isValid)
        #expect(HotKeyShortcut.defaultVolumeDown.isValid)
        #expect(HotKeyShortcut.defaultVolumeUp.displayName == "⌃⌘↑")
        #expect(HotKeyShortcut.defaultVolumeDown.displayName == "⌃⌘↓")
    }

    @Test("Bare and one-modifier keys are rejected")
    func unsafeShortcutsAreRejected() {
        #expect(!HotKeyShortcut(
            keyCode: 126, modifiers: [], keyLabel: "↑").isValid)
        #expect(!HotKeyShortcut(
            keyCode: 126, modifiers: [.command], keyLabel: "↑").isValid)
        #expect(!HotKeyShortcut(
            keyCode: 18, modifiers: [.option, .shift], keyLabel: "1").isValid)
    }

    @Test("A shortcut round-trips through persisted JSON")
    func persistenceRoundTrip() throws {
        let shortcut = HotKeyShortcut(
            keyCode: 124,
            modifiers: [.control, .shift, .command],
            keyLabel: "→")
        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(HotKeyShortcut.self, from: data)
        #expect(decoded == shortcut)
    }
}
