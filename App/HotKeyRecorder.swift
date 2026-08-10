import AppKit
import SwiftUI

struct HotKeyRecorder: NSViewRepresentable {
    @Binding var shortcut: HotKeyShortcut

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: $shortcut)
    }

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        let coordinator = context.coordinator
        button.onShortcut = { shortcut in
            coordinator.shortcut.wrappedValue = shortcut
        }
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        context.coordinator.shortcut = $shortcut
        button.shortcut = shortcut
        button.recordingTitle = AppL10n.text(
            "hotkey.recording", defaultValue: "Type Shortcut…")
        button.setAccessibilityLabel(AppL10n.text(
            "hotkey.recorder.accessibility", defaultValue: "Record keyboard shortcut"))
    }

    final class Coordinator {
        var shortcut: Binding<HotKeyShortcut>

        init(shortcut: Binding<HotKeyShortcut>) {
            self.shortcut = shortcut
        }
    }
}

@MainActor
final class RecorderButton: NSButton {
    var shortcut = HotKeyShortcut.defaultVolumeUp {
        didSet { refreshTitle() }
    }
    var recordingTitle = "Type Shortcut…" {
        didSet { refreshTitle() }
    }
    var onShortcut: ((HotKeyShortcut) -> Void)?

    private var isRecording = false {
        didSet { refreshTitle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .regular
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { isRecording = false }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if capture(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if capture(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func capture(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if event.keyCode == 53 {
            isRecording = false
            window?.makeFirstResponder(nil)
            return true
        }
        guard let shortcut = HotKeyShortcut(event: event) else {
            NSSound.beep()
            return true
        }
        self.shortcut = shortcut
        onShortcut?(shortcut)
        isRecording = false
        window?.makeFirstResponder(nil)
        return true
    }

    private func refreshTitle() {
        title = isRecording ? recordingTitle : shortcut.displayName
        setAccessibilityValue(shortcut.displayName)
    }
}
