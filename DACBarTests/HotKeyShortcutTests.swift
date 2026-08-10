import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import DACBar

@Suite("Global hot-key preferences", .serialized)
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

    @Test("Registration identity ignores the layout-derived label")
    func registrationIdentityIgnoresLabel() {
        let qwerty = HotKeyShortcut(
            keyCode: 0,
            modifiers: [.control, .command],
            keyLabel: "A")
        let dvorak = HotKeyShortcut(
            keyCode: 0,
            modifiers: [.control, .command],
            keyLabel: "Q")

        #expect(qwerty != dvorak)
        #expect(qwerty.registrationIdentity == dvorak.registrationIdentity)
    }

    @MainActor
    @Test("Controller rejects duplicate physical hotkeys across layouts")
    func duplicateRegistrationAcrossLayouts() {
        let suiteName = "DACBarTests.hotkeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = GlobalHotKeyController(defaults: defaults) { _ in }
        controller.beginShortcutRecording()
        controller.setShortcut(
            HotKeyShortcut(
                keyCode: 0,
                modifiers: [.control, .command],
                keyLabel: "A"),
            for: .increase)
        controller.setShortcut(
            HotKeyShortcut(
                keyCode: 0,
                modifiers: [.control, .command],
                keyLabel: "Q"),
            for: .decrease)
        controller.setEnabled(true)
        controller.endShortcutRecording()

        #expect(controller.status == .duplicate)
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

    @MainActor
    @Test("Handler installation failures prevent registration")
    func handlerInstallationFailure() {
        let (defaults, suiteName) = makeEnabledDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fake = HotKeyPlatformFake()
        fake.installationError = -9_001

        let controller = GlobalHotKeyController(
            defaults: defaults, platform: fake.platform()) { _ in }

        #expect(controller.status == .failed(-9_001))
        #expect(fake.registeredDirections.isEmpty)
    }

    @MainActor
    @Test("Partial registration failures tear down successful hotkeys")
    func registrationFailureTearsDownPartialRegistration() {
        let (defaults, suiteName) = makeEnabledDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fake = HotKeyPlatformFake()
        fake.registrationErrorByDirection[.decrease] = -9_002

        var controller: GlobalHotKeyController? = GlobalHotKeyController(
            defaults: defaults, platform: fake.platform()) { _ in }

        #expect(controller?.status == .failed(-9_002))
        #expect(fake.registeredDirections == [.increase, .decrease])
        #expect(fake.unregisteredDirections == [.increase])
        controller = nil
        #expect(fake.removedHandlerCount == 1)
    }

    @MainActor
    @Test("Installed Carbon delivery routes registered direction identifiers")
    func installedDeliveryRoutesEvents() {
        let (defaults, suiteName) = makeEnabledDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fake = HotKeyPlatformFake()
        var delivered: [HotKeyDirection] = []
        let controller = GlobalHotKeyController(
            defaults: defaults,
            platform: fake.platform(),
            onDirection: { delivered.append($0) })

        #expect(controller.status == .registered)
        fake.deliver(signature: 0x4441_4342, id: HotKeyDirection.increase.rawValue)
        fake.deliver(signature: 0x4441_4342, id: 99)
        fake.deliver(signature: 0x4441_4342, id: HotKeyDirection.decrease.rawValue)
        #expect(delivered == [.increase, .decrease])

        controller.setEnabled(false)
        fake.deliver(signature: 0x4441_4342, id: HotKeyDirection.increase.rawValue)
        #expect(delivered == [.increase, .decrease])
    }

    @MainActor
    @Test("Foreign Carbon hot-key signatures are ignored")
    func foreignCarbonSignatureIsIgnored() {
        let (defaults, suiteName) = makeEnabledDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fake = HotKeyPlatformFake()
        var delivered: [HotKeyDirection] = []
        let controller = GlobalHotKeyController(
            defaults: defaults,
            platform: fake.platform(),
            onDirection: { delivered.append($0) })

        #expect(controller.status == .registered)
        fake.deliver(signature: 0x5445_5354, id: HotKeyDirection.increase.rawValue)
        #expect(delivered.isEmpty)

        fake.deliver(signature: 0x4441_4342, id: HotKeyDirection.increase.rawValue)
        #expect(delivered == [.increase])
    }

    @MainActor
    @Test("A Carbon hot-key event is extracted and routed through the live handler")
    func liveCarbonEventDelivery() async throws {
        let (defaults, suiteName) = makeEnabledDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fake = HotKeyPlatformFake()
        let registration = fake.platform()
        let live = GlobalHotKeyPlatform.live
        let platform = GlobalHotKeyPlatform(
            installEventHandler: live.installEventHandler,
            removeEventHandler: live.removeEventHandler,
            registerHotKey: registration.registerHotKey,
            unregisterHotKey: registration.unregisterHotKey)
        let deliveries = AsyncStream.makeStream(of: HotKeyDirection.self)
        defer { deliveries.continuation.finish() }
        let controller = GlobalHotKeyController(
            defaults: defaults,
            platform: platform,
            onDirection: { deliveries.continuation.yield($0) })
        #expect(controller.status == .registered)

        var createdEvent: EventRef?
        #expect(CreateEvent(
            nil,
            OSType(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            GetCurrentEventTime(),
            EventAttributes(kEventAttributeNone),
            &createdEvent) == noErr)
        let event = try #require(createdEvent)
        defer { ReleaseEvent(event) }
        var identifier = EventHotKeyID(signature: 0x4441_4342, id: 1) // "DACB"
        #expect(SetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            &identifier) == noErr)
        #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)

        let delivered = try await firstHotKeyDelivery(
            from: deliveries.stream, timeout: .seconds(1))
        #expect(delivered == .increase)
    }

    @MainActor
    private func makeEnabledDefaults() -> (UserDefaults, String) {
        let suiteName = "DACBarTests.hotkey-platform.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: AppPreferenceKey.hotKeysEnabled)
        return (defaults, suiteName)
    }
}

@MainActor
private final class HotKeyPlatformFake {
    final class HandlerToken: NSObject {}
    final class RegistrationToken: NSObject {
        let direction: HotKeyDirection

        init(direction: HotKeyDirection) {
            self.direction = direction
        }
    }

    var installationError: OSStatus?
    var registrationErrorByDirection: [HotKeyDirection: OSStatus] = [:]
    private(set) var registeredDirections: [HotKeyDirection] = []
    private(set) var unregisteredDirections: [HotKeyDirection] = []
    private(set) var removedHandlerCount = 0
    private var delivery: (@MainActor @Sendable (HotKeyEventIdentifier) -> Void)?

    func platform() -> GlobalHotKeyPlatform {
        GlobalHotKeyPlatform(
            installEventHandler: { [weak self] delivery in
                guard let self else { return .failure(-1) }
                self.delivery = delivery
                if let installationError = self.installationError {
                    return .failure(installationError)
                }
                return .success(HandlerToken())
            },
            removeEventHandler: { [weak self] _ in
                self?.removedHandlerCount += 1
            },
            registerHotKey: { [weak self] _, direction in
                guard let self else { return .failure(-1) }
                self.registeredDirections.append(direction)
                if let error = self.registrationErrorByDirection[direction] {
                    return .failure(error)
                }
                return .success(RegistrationToken(direction: direction))
            },
            unregisterHotKey: { [weak self] token in
                guard let token = token as? RegistrationToken else { return }
                self?.unregisteredDirections.append(token.direction)
            })
    }

    func deliver(signature: OSType, id: UInt32) {
        delivery?(HotKeyEventIdentifier(signature: signature, id: id))
    }
}

private enum HotKeyDeliveryTestError: Error {
    case streamFinished
    case timeout
}

private func firstHotKeyDelivery(
    from stream: AsyncStream<HotKeyDirection>,
    timeout: Duration
) async throws -> HotKeyDirection {
    try await withThrowingTaskGroup(of: HotKeyDirection.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let direction = await iterator.next() else {
                throw HotKeyDeliveryTestError.streamFinished
            }
            return direction
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw HotKeyDeliveryTestError.timeout
        }
        guard let direction = try await group.next() else {
            throw HotKeyDeliveryTestError.streamFinished
        }
        group.cancelAll()
        return direction
    }
}
