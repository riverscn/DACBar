import Carbon.HIToolbox
import Foundation
import Observation

enum HotKeyDirection: UInt32, Sendable {
    case increase = 1
    case decrease = 2
}

@MainActor
@Observable
final class GlobalHotKeyController {
    enum RegistrationStatus: Equatable {
        case disabled
        case registered
        case duplicate
        case failed(OSStatus)
    }

    private(set) var isEnabled: Bool
    private(set) var volumeUp: HotKeyShortcut
    private(set) var volumeDown: HotKeyShortcut
    private(set) var status: RegistrationStatus = .disabled

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onDirection: (HotKeyDirection) -> Void
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private var handlerInstallationResult: OSStatus = noErr
    @ObservationIgnored private var registrations: [UInt32: EventHotKeyRef] = [:]

    private static let signature: OSType = 0x4441_4342 // "DACB"

    init(
        defaults: UserDefaults = .standard,
        onDirection: @escaping (HotKeyDirection) -> Void
    ) {
        self.defaults = defaults
        self.onDirection = onDirection
        isEnabled = defaults.bool(forKey: AppPreferenceKey.hotKeysEnabled)
        volumeUp = Self.loadShortcut(
            AppPreferenceKey.volumeUpShortcut,
            fallback: .defaultVolumeUp,
            defaults: defaults)
        volumeDown = Self.loadShortcut(
            AppPreferenceKey.volumeDownShortcut,
            fallback: .defaultVolumeDown,
            defaults: defaults)

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        handlerInstallationResult = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandlerCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler)
        applyRegistration()
    }

    isolated deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.hotKeysEnabled)
        applyRegistration()
    }

    func setShortcut(_ shortcut: HotKeyShortcut, for direction: HotKeyDirection) {
        guard shortcut.isValid else { return }
        switch direction {
        case .increase:
            volumeUp = shortcut
            Self.saveShortcut(
                shortcut, key: AppPreferenceKey.volumeUpShortcut, defaults: defaults)
        case .decrease:
            volumeDown = shortcut
            Self.saveShortcut(
                shortcut, key: AppPreferenceKey.volumeDownShortcut, defaults: defaults)
        }
        applyRegistration()
    }

    func restoreDefaults() {
        volumeUp = .defaultVolumeUp
        volumeDown = .defaultVolumeDown
        Self.saveShortcut(
            volumeUp, key: AppPreferenceKey.volumeUpShortcut, defaults: defaults)
        Self.saveShortcut(
            volumeDown, key: AppPreferenceKey.volumeDownShortcut, defaults: defaults)
        applyRegistration()
    }

    private func applyRegistration() {
        unregisterAll()
        guard isEnabled else {
            status = .disabled
            return
        }
        guard handlerInstallationResult == noErr else {
            status = .failed(handlerInstallationResult)
            return
        }
        guard volumeUp != volumeDown else {
            status = .duplicate
            return
        }

        for (direction, shortcut) in [
            (HotKeyDirection.increase, volumeUp),
            (HotKeyDirection.decrease, volumeDown),
        ] {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(
                signature: Self.signature, id: direction.rawValue)
            let result = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers.carbonFlags,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference)
            guard result == noErr, let reference else {
                unregisterAll()
                status = .failed(result)
                return
            }
            registrations[direction.rawValue] = reference
        }
        status = .registered
    }

    private func unregisterAll() {
        for reference in registrations.values {
            UnregisterEventHotKey(reference)
        }
        registrations.removeAll()
    }

    private func received(identifier: UInt32) {
        guard isEnabled,
              status == .registered,
              let direction = HotKeyDirection(rawValue: identifier)
        else { return }
        onDirection(direction)
    }

    nonisolated private static let eventHandlerCallback: EventHandlerUPP = {
        _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let result = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier)
        guard result == noErr else { return result }
        let controller = Unmanaged<GlobalHotKeyController>
            .fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            controller.received(identifier: identifier.id)
        }
        return noErr
    }

    private static func loadShortcut(
        _ key: String,
        fallback: HotKeyShortcut,
        defaults: UserDefaults
    ) -> HotKeyShortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
              shortcut.isValid
        else { return fallback }
        return shortcut
    }

    private static func saveShortcut(
        _ shortcut: HotKeyShortcut,
        key: String,
        defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }
}

private extension HotKeyModifiers {
    var carbonFlags: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
