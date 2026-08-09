import CoreFoundation
import Foundation
import IOKit
import IOKit.hid
import OSLog
import DACDeviceKit

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
    private static let eventTrackingRunLoopMode = CFRunLoopMode(
        rawValue: "NSEventTrackingRunLoopMode" as CFString)

    private(set) var devices: [AttachedDevice] = []

    var isPresent: Bool { !devices.isEmpty }
    var onChange: (([AttachedDevice]) -> Void)?
    var onFailure: ((String) -> Void)?

    private var manager: IOHIDManager?
    private var runLoop: CFRunLoop?
    private var settle: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() throws {
        guard manager == nil else { return }

        let created = IOHIDManagerCreate(
            kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(
            created, SupportedDevices.hidMatchingDictionaries())
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            created, Self.matchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(
            created, Self.removedCallback, context)

        let openResult = IOHIDManagerOpen(created, 0)
        guard openResult == kIOReturnSuccess else {
            throw DeviceWatcherFailure.managerOpen(openResult)
        }

        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            IOHIDManagerClose(created, 0)
            throw DeviceWatcherFailure.runLoop
        }
        CFRunLoopAddCommonMode(currentRunLoop, Self.eventTrackingRunLoopMode)
        IOHIDManagerScheduleWithRunLoop(
            created, currentRunLoop, CFRunLoopMode.commonModes.rawValue)
        manager = created
        runLoop = currentRunLoop

        do {
            devices = try Self.probe()
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

        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        if let runLoop {
            IOHIDManagerUnscheduleFromRunLoop(
                manager, runLoop, CFRunLoopMode.commonModes.rawValue)
        }
        IOHIDManagerClose(manager, 0)
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
        try Self.probe()
    }

    private static let matchedCallback: IOHIDDeviceCallback = {
        context, result, _, _ in
        guard let context else { return }
        let watcher = Unmanaged<DeviceWatcher>
            .fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            guard result == kIOReturnSuccess else {
                watcher.reportCallbackFailure(result)
                return
            }
            watcher.deviceMatched()
        }
    }

    private static let removedCallback: IOHIDDeviceCallback = {
        context, result, _, _ in
        guard let context else { return }
        let watcher = Unmanaged<DeviceWatcher>
            .fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            guard result == kIOReturnSuccess else {
                watcher.reportCallbackFailure(result)
                return
            }
            watcher.deviceRemoved()
        }
    }

    // MARK: - Passive events

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
        settle = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                self.settle = nil
                self.refresh(reason: "settled removal")
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error(
                    "Removal settle failed: \(error.localizedDescription)")
            }
        }
    }

    private func refresh(reason: String) {
        do {
            publish(try Self.probe(), reason: reason)
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
