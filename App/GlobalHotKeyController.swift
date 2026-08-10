import Carbon.HIToolbox
import Foundation
import Observation

@MainActor
struct GlobalHotKeyPlatform {
    enum TokenResult {
        case success(AnyObject)
        case failure(OSStatus)
    }

    let installEventHandler:
        (@escaping @MainActor @Sendable (UInt32) -> Void) -> TokenResult
    let removeEventHandler: (AnyObject) -> Void
    let registerHotKey: (HotKeyShortcut, HotKeyDirection) -> TokenResult
    let unregisterHotKey: (AnyObject) -> Void

    static let live = GlobalHotKeyPlatform(
        installEventHandler: { delivery in
            let context = CarbonHotKeyEventContext(delivery: delivery)
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed))
            var handler: EventHandlerRef?
            let result = InstallEventHandler(
                GetApplicationEventTarget(),
                carbonHotKeyEventHandler,
                1,
                &eventType,
                Unmanaged.passUnretained(context).toOpaque(),
                &handler)
            guard result == noErr, let handler else {
                return .failure(result == noErr ? OSStatus(eventInternalErr) : result)
            }
            return .success(CarbonEventHandlerToken(handler: handler, context: context))
        },
        removeEventHandler: { token in
            guard let token = token as? CarbonEventHandlerToken else { return }
            RemoveEventHandler(token.handler)
        },
        registerHotKey: { shortcut, direction in
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(
                signature: GlobalHotKeyController.signature, id: direction.rawValue)
            let result = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers.carbonFlags,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference)
            guard result == noErr, let reference else {
                return .failure(result == noErr ? OSStatus(eventInternalErr) : result)
            }
            return .success(CarbonHotKeyToken(reference: reference))
        },
        unregisterHotKey: { token in
            guard let token = token as? CarbonHotKeyToken else { return }
            UnregisterEventHotKey(token.reference)
        })
}

private final class CarbonHotKeyEventContext: @unchecked Sendable {
    let delivery: @MainActor @Sendable (UInt32) -> Void

    init(delivery: @escaping @MainActor @Sendable (UInt32) -> Void) {
        self.delivery = delivery
    }
}

private final class CarbonEventHandlerToken {
    let handler: EventHandlerRef
    // Carbon keeps an unretained pointer to this context until handler removal.
    let context: CarbonHotKeyEventContext

    init(handler: EventHandlerRef, context: CarbonHotKeyEventContext) {
        self.handler = handler
        self.context = context
    }
}

private final class CarbonHotKeyToken {
    let reference: EventHotKeyRef

    init(reference: EventHotKeyRef) {
        self.reference = reference
    }
}

nonisolated private let carbonHotKeyEventHandler: EventHandlerUPP = {
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
    let context = Unmanaged<CarbonHotKeyEventContext>
        .fromOpaque(userData).takeUnretainedValue()
    let delivery = context.delivery
    Task { @MainActor in
        delivery(identifier.id)
    }
    return noErr
}

enum HotKeyDirection: UInt32, Sendable {
    case increase = 1
    case decrease = 2
}

@MainActor
@Observable
final class GlobalHotKeyController {
    enum RegistrationStatus: Equatable {
        case disabled
        case suspended
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
    @ObservationIgnored private let platform: GlobalHotKeyPlatform
    @ObservationIgnored private var eventHandler: AnyObject?
    @ObservationIgnored private var handlerInstallationResult: OSStatus = noErr
    @ObservationIgnored private var registrations: [UInt32: AnyObject] = [:]
    @ObservationIgnored private var recordingSuspensionCount = 0

    fileprivate static let signature: OSType = 0x4441_4342 // "DACB"

    init(
        defaults: UserDefaults = .standard,
        platform: GlobalHotKeyPlatform = .live,
        onDirection: @escaping (HotKeyDirection) -> Void
    ) {
        self.defaults = defaults
        self.platform = platform
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

        switch platform.installEventHandler({ [weak self] identifier in
            self?.received(identifier: identifier)
        }) {
        case .success(let eventHandler):
            self.eventHandler = eventHandler
        case .failure(let result):
            handlerInstallationResult = result
        }
        applyRegistration()
    }

    isolated deinit {
        unregisterAll()
        if let eventHandler { platform.removeEventHandler(eventHandler) }
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

    /// Carbon consumes registered shortcuts before the recorder's first responder
    /// can see them. Keep registration suspended for every active recorder; the
    /// count also covers the brief overlap when focus moves between the two
    /// recorder buttons.
    func beginShortcutRecording() {
        recordingSuspensionCount += 1
        if recordingSuspensionCount == 1 {
            applyRegistration()
        }
    }

    func endShortcutRecording() {
        guard recordingSuspensionCount > 0 else { return }
        recordingSuspensionCount -= 1
        if recordingSuspensionCount == 0 {
            applyRegistration()
        }
    }

    private func applyRegistration() {
        unregisterAll()
        guard isEnabled else {
            status = .disabled
            return
        }
        guard recordingSuspensionCount == 0 else {
            status = .suspended
            return
        }
        guard volumeUp.registrationIdentity != volumeDown.registrationIdentity else {
            status = .duplicate
            return
        }
        guard handlerInstallationResult == noErr else {
            status = .failed(handlerInstallationResult)
            return
        }

        for (direction, shortcut) in [
            (HotKeyDirection.increase, volumeUp),
            (HotKeyDirection.decrease, volumeDown),
        ] {
            switch platform.registerHotKey(shortcut, direction) {
            case .success(let reference):
                registrations[direction.rawValue] = reference
            case .failure(let result):
                unregisterAll()
                status = .failed(result)
                return
            }
        }
        status = .registered
    }

    private func unregisterAll() {
        for reference in registrations.values {
            platform.unregisterHotKey(reference)
        }
        registrations.removeAll()
    }

    private func received(identifier: UInt32) {
        guard isEnabled,
              recordingSuspensionCount == 0,
              status == .registered,
              let direction = HotKeyDirection(rawValue: identifier)
        else { return }
        onDirection(direction)
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
