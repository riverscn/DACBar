import CoreFoundation
import Foundation
import IOKit
import IOKit.hid
import OSLog
import DACDeviceKit

@MainActor
protocol DeviceWatcherSettleCancellation: AnyObject {
    func cancel()
}

@MainActor
private final class LiveDeviceWatcherSettle: DeviceWatcherSettleCancellation {
    private static let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier, category: "device-watcher")
    private let task: Task<Void, Never>

    init(operation: @escaping @MainActor @Sendable () -> Void) {
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(400))
                operation()
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error(
                    "Removal settle failed: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        task.cancel()
    }
}

@MainActor
struct DeviceWatcherPlatform {
    let createManager: () -> IOHIDManager
    let configureMatching: (IOHIDManager) -> Void
    let installCallbacks: (
        IOHIDManager,
        @escaping @MainActor @Sendable (IOReturn) -> Void,
        @escaping @MainActor @Sendable (IOReturn) -> Void
    ) -> AnyObject
    let clearCallbacks: (IOHIDManager) -> Void
    let open: (IOHIDManager) -> IOReturn
    let currentRunLoop: () -> CFRunLoop?
    let addEventTrackingMode: (CFRunLoop) -> Void
    let schedule: (IOHIDManager, CFRunLoop) -> Void
    let unschedule: (IOHIDManager, CFRunLoop) -> Void
    let close: (IOHIDManager) -> Void
    let probe: () throws -> [AttachedDevice]
    let scheduleRemovalSettle:
        (@escaping @MainActor @Sendable () -> Void) -> any DeviceWatcherSettleCancellation

    static let live = DeviceWatcherPlatform(
        createManager: {
            IOHIDManagerCreate(
                kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        },
        configureMatching: {
            IOHIDManagerSetDeviceMatchingMultiple(
                $0, SupportedDevices.hidMatchingDictionaries())
        },
        installCallbacks: { manager, matched, removed in
            let context = DeviceWatcherCallbackContext(
                matched: matched, removed: removed)
            let pointer = Unmanaged.passUnretained(context).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(
                manager, deviceWatcherMatchedCallback, pointer)
            IOHIDManagerRegisterDeviceRemovalCallback(
                manager, deviceWatcherRemovedCallback, pointer)
            return context
        },
        clearCallbacks: {
            IOHIDManagerRegisterDeviceMatchingCallback($0, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback($0, nil, nil)
        },
        open: { IOHIDManagerOpen($0, 0) },
        currentRunLoop: { CFRunLoopGetCurrent() },
        addEventTrackingMode: {
            CFRunLoopAddCommonMode(
                $0,
                CFRunLoopMode(rawValue: "NSEventTrackingRunLoopMode" as CFString))
        },
        schedule: {
            IOHIDManagerScheduleWithRunLoop(
                $0, $1, CFRunLoopMode.commonModes.rawValue)
        },
        unschedule: {
            IOHIDManagerUnscheduleFromRunLoop(
                $0, $1, CFRunLoopMode.commonModes.rawValue)
        },
        close: { IOHIDManagerClose($0, 0) },
        probe: { try SupportedDevices.devices().map(AttachedDevice.init) },
        scheduleRemovalSettle: { LiveDeviceWatcherSettle(operation: $0) })
}

private final class DeviceWatcherCallbackContext: @unchecked Sendable {
    let matched: @MainActor @Sendable (IOReturn) -> Void
    let removed: @MainActor @Sendable (IOReturn) -> Void

    init(
        matched: @escaping @MainActor @Sendable (IOReturn) -> Void,
        removed: @escaping @MainActor @Sendable (IOReturn) -> Void
    ) {
        self.matched = matched
        self.removed = removed
    }
}

nonisolated private let deviceWatcherMatchedCallback: IOHIDDeviceCallback = {
    context, result, _, _ in
    guard let context else { return }
    let callback = Unmanaged<DeviceWatcherCallbackContext>
        .fromOpaque(context).takeUnretainedValue().matched
    MainActor.assumeIsolated { callback(result) }
}

nonisolated private let deviceWatcherRemovedCallback: IOHIDDeviceCallback = {
    context, result, _, _ in
    guard let context else { return }
    let callback = Unmanaged<DeviceWatcherCallbackContext>
        .fromOpaque(context).takeUnretainedValue().removed
    MainActor.assumeIsolated { callback(result) }
}

@MainActor
protocol DeviceWatching: AnyObject {
    var devices: [AttachedDevice] { get }
    var onChange: (([AttachedDevice]) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start() throws
    func stop()
    func probe() throws -> [AttachedDevice]
}

private enum DeviceWatcherFailure: LocalizedError {
    case managerOpen(IOReturn)
    case runLoop

    var errorDescription: String? {
        switch self {
        case .managerOpen(let result):
            return AppL10n.format(
                "error.hid-watch",
                defaultValue: "Unable to monitor HID device changes (0x%08X).",
                UInt32(bitPattern: result))
        case .runLoop:
            return AppL10n.text(
                "error.main-run-loop", defaultValue: "Unable to access the main run loop.")
        }
    }
}

/// Tracks supported HID services with the same matching layer used by the
/// transport itself. A USB device notification is too early for a composite
/// device: its HID service may appear later or be recreated independently.
@MainActor
final class DeviceWatcher: DeviceWatching {

    private static let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier, category: "device-watcher")
    private(set) var devices: [AttachedDevice] = []

    var isPresent: Bool { !devices.isEmpty }
    var onChange: (([AttachedDevice]) -> Void)?
    var onFailure: ((String) -> Void)?

    private let platform: DeviceWatcherPlatform
    private var manager: IOHIDManager?
    private var runLoop: CFRunLoop?
    private var callbackToken: AnyObject?
    private var settle: (any DeviceWatcherSettleCancellation)?

    init(platform: DeviceWatcherPlatform = .live) {
        self.platform = platform
    }

    // MARK: - Lifecycle

    func start() throws {
        guard manager == nil else { return }

        let created = platform.createManager()
        platform.configureMatching(created)
        callbackToken = platform.installCallbacks(
            created,
            { [weak self] result in self?.receivedMatch(result) },
            { [weak self] result in self?.receivedRemoval(result) })
        manager = created

        let openResult = platform.open(created)
        guard openResult == kIOReturnSuccess else {
            stop()
            throw DeviceWatcherFailure.managerOpen(openResult)
        }

        guard let currentRunLoop = platform.currentRunLoop() else {
            stop()
            throw DeviceWatcherFailure.runLoop
        }
        platform.addEventTrackingMode(currentRunLoop)
        platform.schedule(created, currentRunLoop)
        runLoop = currentRunLoop

        do {
            devices = try platform.probe()
            Self.logger.info(
                "HID watcher started with \(self.devices.count, privacy: .public) device(s)")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        settle?.cancel()
        settle = nil
        guard let manager else { return }

        platform.clearCallbacks(manager)
        callbackToken = nil
        if let runLoop {
            platform.unschedule(manager, runLoop)
        }
        platform.close(manager)
        self.manager = nil
        runLoop = nil
    }

    isolated deinit {
        stop()
    }

    // MARK: - Matching

    /// Used only for the initial snapshot and to coalesce the registry around
    /// a passive callback. There is no timer or periodic presence polling.
    static func probe() throws -> [AttachedDevice] {
        try SupportedDevices.devices().map(AttachedDevice.init)
    }

    func probe() throws -> [AttachedDevice] {
        try platform.probe()
    }

    // MARK: - Passive events

    private func receivedMatch(_ result: IOReturn) {
        guard result == kIOReturnSuccess else {
            reportCallbackFailure(result)
            return
        }
        deviceMatched()
    }

    private func receivedRemoval(_ result: IOReturn) {
        guard result == kIOReturnSuccess else {
            reportCallbackFailure(result)
            return
        }
        deviceRemoved()
    }

    private func deviceMatched() {
        settle?.cancel()
        settle = nil
        Self.logger.info("HID matching callback received")
        refresh(reason: "matching callback")
    }

    private func deviceRemoved() {
        settle?.cancel()
        Self.logger.info("HID removal callback received")
        refresh(reason: "removal callback")

        // The callback can precede final registry teardown. One delayed
        // coalescing read is event-driven—not polling—and ensures the old
        // service has disappeared before publishing the settled snapshot.
        settle = platform.scheduleRemovalSettle { [weak self] in
            guard let self else { return }
            self.settle = nil
            self.refresh(reason: "settled removal")
        }
    }

    private func refresh(reason: String) {
        do {
            publish(try platform.probe(), reason: reason)
        } catch {
            Self.logger.error("Device probe failed: \(error.localizedDescription)")
            onFailure?(error.localizedDescription)
        }
    }

    private func publish(_ current: [AttachedDevice], reason: String) {
        guard current != devices else { return }
        let oldCount = devices.count
        devices = current
        Self.logger.info(
            "Published HID devices reason=\(reason, privacy: .public) old=\(oldCount, privacy: .public) new=\(current.count, privacy: .public)")
        onChange?(current)
    }

    private func reportCallbackFailure(_ result: IOReturn) {
        let message = AppL10n.format(
            "error.hid-notification",
            defaultValue: "HID device notification failed (0x%08X).",
            UInt32(bitPattern: result))
        Self.logger.error("\(message, privacy: .public)")
        onFailure?(message)
    }
}
