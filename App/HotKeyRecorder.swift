import AppKit
import SwiftUI

struct HotKeyRecorder: NSViewRepresentable {
    @Binding var shortcut: HotKeyShortcut
    let onRecordingChanged: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shortcut: $shortcut,
            onRecordingChanged: onRecordingChanged)
    }

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        let coordinator = context.coordinator
        button.onShortcut = { shortcut in
            coordinator.shortcut.wrappedValue = shortcut
        }
        button.onRecordingChanged = { isRecording in
            coordinator.onRecordingChanged(isRecording)
        }
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        context.coordinator.shortcut = $shortcut
        context.coordinator.onRecordingChanged = onRecordingChanged
        button.shortcut = shortcut
        button.recordingTitle = AppL10n.text(
            "hotkey.recording", defaultValue: "Type Shortcut…")
        button.setAccessibilityLabel(AppL10n.text(
            "hotkey.recorder.accessibility", defaultValue: "Record keyboard shortcut"))
    }

    static func dismantleNSView(_ button: RecorderButton, coordinator: Coordinator) {
        button.cancelRecording()
    }

    @MainActor
    final class Coordinator {
        var shortcut: Binding<HotKeyShortcut>
        var onRecordingChanged: @MainActor (Bool) -> Void

        init(
            shortcut: Binding<HotKeyShortcut>,
            onRecordingChanged: @escaping @MainActor (Bool) -> Void
        ) {
            self.shortcut = shortcut
            self.onRecordingChanged = onRecordingChanged
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
    var onRecordingChanged: ((Bool) -> Void)?

    private(set) var isRecording = false

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

    @objc func beginRecording() {
        guard !isRecording else { return }
        setRecording(true)
        guard window?.makeFirstResponder(self) == true else {
            setRecording(false)
            return
        }
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setRecording(false) }
        return result
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window)
        }
    }

    func cancelRecording() {
        setRecording(false)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        cancelRecording()
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
            cancelRecording()
            window?.makeFirstResponder(nil)
            return true
        }
        guard let shortcut = HotKeyShortcut(event: event) else {
            NSSound.beep()
            return true
        }
        self.shortcut = shortcut
        onShortcut?(shortcut)
        cancelRecording()
        window?.makeFirstResponder(nil)
        return true
    }

    private func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        refreshTitle()
        onRecordingChanged?(recording)
    }

    private func refreshTitle() {
        title = isRecording ? recordingTitle : shortcut.displayName
        setAccessibilityValue(shortcut.displayName)
    }
}
