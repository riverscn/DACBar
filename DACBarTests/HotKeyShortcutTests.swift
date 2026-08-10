import AppKit
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

    @MainActor
    @Test("Global registration stays suspended across overlapping recorders")
    func recordingSuspensionIsBalanced() {
        let suiteName = "DACBarTests.hotkeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = GlobalHotKeyController(defaults: defaults) { _ in }
        controller.beginShortcutRecording()
        controller.setEnabled(true)
        #expect(controller.status == .suspended)

        controller.beginShortcutRecording()
        controller.endShortcutRecording()
        #expect(controller.status == .suspended)

        // Disable before ending the final session so this unit test never
        // reserves real system-wide shortcuts on the host running the tests.
        controller.setEnabled(false)
        controller.endShortcutRecording()
        #expect(controller.status == .disabled)
    }

    @MainActor
    @Test("Recorder resumes global shortcuts when its window loses focus")
    func recorderEndsWhenWindowResignsKey() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let button = RecorderButton()
        window.contentView = button
        var recordingStates: [Bool] = []
        button.onRecordingChanged = { recordingStates.append($0) }

        button.beginRecording()
        #expect(button.isRecording)
        #expect(recordingStates == [true])

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: window)
        #expect(!button.isRecording)
        #expect(recordingStates == [true, false])
    }
}
