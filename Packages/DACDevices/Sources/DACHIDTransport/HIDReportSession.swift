import CoreFoundation
import Foundation
import IOKit
import IOKit.hid
import DACDeviceKit

public enum DACHIDTransport {}

extension DACHIDTransport {
    public enum Failure: Error, Equatable, Sendable {
        case managerFailed(IOReturn)
        case deviceNotFound
    }

    /// Shared IOHID discovery for device plug-ins. Product strings remain
    /// descriptive; ownership is resolved from the complete HID signature.
    public enum DeviceDiscovery {
        public static func devices(
            in registry: DACDeviceKit.DeviceRegistry
        ) throws -> [DACDeviceKit.Device] {
            let manager = IOHIDManagerCreate(
                kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            setMatching(manager, profiles: registry.profiles)
            let result = IOHIDManagerOpen(manager, 0)
            guard result == kIOReturnSuccess else {
                throw Failure.managerFailed(result)
            }
            defer { IOHIDManagerClose(manager, 0) }

            let all = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
            return discardingAmbiguousRegistryEntries(
                all.compactMap { discoveredDevice(for: $0, registry: registry) })
        }

        /// IOHID may briefly expose a retiring and replacement service for one
        /// physical port. Neither registry entry is provably newer, so omit the
        /// logical device until a settled snapshot contains exactly one service.
        public static func discardingAmbiguousRegistryEntries(
            _ candidates: [DACDeviceKit.Device]
        ) -> [DACDeviceKit.Device] {
            Dictionary(grouping: candidates, by: \.id).values.compactMap { matches in
                matches.count == 1 ? matches[0] : nil
            }.sorted {
                ($0.locationID, $0.profile.id.rawValue)
                    < ($1.locationID, $1.profile.id.rawValue)
            }
        }

        public static func matchesOpeningIdentity(
            expected: DACDeviceKit.Device,
            actual: DACDeviceKit.Device
        ) -> Bool {
            expected.profile == actual.profile
                && expected.productID == actual.productID
                && expected.locationID == actual.locationID
                && expected.registryEntryID == actual.registryEntryID
        }

        fileprivate static func setMatching(
            _ manager: IOHIDManager,
            profiles: [DACDeviceKit.DeviceProfile]
        ) {
            let dictionaries = profiles
                .filter { $0.discoveryKind == .hidService }
                .flatMap(\.hidMatches)
                .map { match in
                    [
                        kIOHIDVendorIDKey: match.vendorID,
                        kIOHIDProductIDKey: match.productID,
                        kIOHIDPrimaryUsagePageKey: match.usagePage,
                        kIOHIDPrimaryUsageKey: match.usage,
                    ] as CFDictionary
                } as CFArray
            IOHIDManagerSetDeviceMatchingMultiple(manager, dictionaries)
        }

        fileprivate static func discoveredDevice(
            for device: IOHIDDevice,
            registry: DACDeviceKit.DeviceRegistry
        ) -> DACDeviceKit.Device? {
            guard let vendorID = numberProperty(device, kIOHIDVendorIDKey),
                  let productID = numberProperty(device, kIOHIDProductIDKey),
                  let usagePage = numberProperty(device, kIOHIDPrimaryUsagePageKey),
                  let usage = numberProperty(device, kIOHIDPrimaryUsageKey),
                  let input = numberProperty(device, kIOHIDMaxInputReportSizeKey),
                  let output = numberProperty(device, kIOHIDMaxOutputReportSizeKey),
                  let location = property(device, kIOHIDLocationIDKey) as? NSNumber
            else { return nil }
            let productName = property(device, kIOHIDProductKey) as? String ?? ""
            guard let profile = registry.profile(
                vendorID: vendorID,
                productID: productID,
                productName: productName,
                usagePage: usagePage,
                usage: usage,
                inputReportSize: input,
                outputReportSize: output)
            else { return nil }

            var registryEntryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(
                IOHIDDeviceGetService(device), &registryEntryID)
            guard registryEntryID != 0 else { return nil }
            return DACDeviceKit.Device(
                profile: profile,
                productID: productID,
                locationID: UInt32(truncatingIfNeeded: location.intValue),
                registryEntryID: registryEntryID,
                name: productName.isEmpty ? profile.displayName : productName)
        }

        private static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
            IOHIDDeviceGetProperty(device, key as CFString)
        }

        private static func numberProperty(
            _ device: IOHIDDevice,
            _ key: String
        ) -> Int? {
            (property(device, key) as? NSNumber)?.intValue
        }
    }

    /// Owns one exact IOHID service, its callbacks, input storage and every
    /// asynchronous output buffer until IOKit completes with it.
    @MainActor
    public final class ReportSession {
        public var onInput: (([UInt8]) -> Void)?
        public var onRemoved: (() -> Void)?
#if DEBUG
        public var onReportIssuedForTesting: (() -> Void)?
#endif
        public private(set) var isClosed = false

        private static let eventTrackingRunLoopMode = CFRunLoopMode(
            rawValue: "NSEventTrackingRunLoopMode" as CFString)

        private let manager: IOHIDManager
        private let device: IOHIDDevice
        private let runLoop: CFRunLoop
        private let inputBufferCapacity: Int
        private var inputBuffer: UnsafeMutablePointer<UInt8>?
        private var ioTornDown = false
        private var activeSendCount = 0

        public init(
            device expected: DACDeviceKit.Device,
            registry: DACDeviceKit.DeviceRegistry,
            inputBufferCapacity: Int = 64
        ) throws {
            precondition(inputBufferCapacity > 0)
            guard registry.profile(id: expected.profile.id) == expected.profile else {
                throw Failure.deviceNotFound
            }

            let manager = IOHIDManagerCreate(
                kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            DeviceDiscovery.setMatching(manager, profiles: [expected.profile])
            let result = IOHIDManagerOpen(manager, 0)
            guard result == kIOReturnSuccess else {
                throw Failure.managerFailed(result)
            }

            let all = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
            let match = all.first { candidate in
                guard let actual = DeviceDiscovery.discoveredDevice(
                    for: candidate, registry: registry)
                else { return false }
                return DeviceDiscovery.matchesOpeningIdentity(
                    expected: expected, actual: actual)
            }
            guard let match else {
                IOHIDManagerClose(manager, 0)
                throw Failure.deviceNotFound
            }

            self.manager = manager
            self.device = match
            self.runLoop = CFRunLoopGetCurrent()
            self.inputBufferCapacity = inputBufferCapacity
            let buffer = UnsafeMutablePointer<UInt8>.allocate(
                capacity: inputBufferCapacity)
            buffer.initialize(repeating: 0, count: inputBufferCapacity)
            self.inputBuffer = buffer

            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(
                match, buffer, inputBufferCapacity,
                { context, _, _, _, _, report, length in
                    guard let context else { return }
                    let session = Unmanaged<ReportSession>
                        .fromOpaque(context).takeUnretainedValue()
                    let frame = Array(UnsafeBufferPointer(
                        start: report, count: Int(length)))
                    MainActor.assumeIsolated { session.received(frame) }
                }, context)
            IOHIDDeviceRegisterRemovalCallback(
                match,
                { context, _, _ in
                    guard let context else { return }
                    let session = Unmanaged<ReportSession>
                        .fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { session.deviceWasRemoved() }
                }, context)
            CFRunLoopAddCommonMode(runLoop, Self.eventTrackingRunLoopMode)
            IOHIDDeviceScheduleWithRunLoop(
                match, runLoop, CFRunLoopMode.commonModes.rawValue)
        }

        public func send(
            _ report: [UInt8],
            reportID: CFIndex,
            timeoutMilliseconds: CFTimeInterval
        ) async -> IOReturn {
            guard !isClosed else { return kIOReturnNotOpen }
            activeSendCount += 1
            let operation = ReportSendOperation(frame: report)
            let result = await withCheckedContinuation { continuation in
                operation.install(continuation)
                let context = Unmanaged.passRetained(operation).toOpaque()
                let immediateResult = IOHIDDeviceSetReportWithCallback(
                    device, kIOHIDReportTypeOutput, reportID,
                    operation.buffer, operation.count, timeoutMilliseconds,
                    { context, result, _, _, _, _, _ in
                        guard let context else { return }
                        let operation = Unmanaged<ReportSendOperation>
                            .fromOpaque(context).takeRetainedValue()
                        operation.finish(result)
                    }, context)
                if immediateResult != kIOReturnSuccess {
                    Unmanaged<ReportSendOperation>.fromOpaque(context).release()
                    operation.finish(immediateResult)
                }
#if DEBUG
                onReportIssuedForTesting?()
#endif
            }
            activeSendCount -= 1
            if isClosed, activeSendCount == 0 { tearDownIO() }
            return result
        }

        public func close() {
            guard !isClosed else { return }
            isClosed = true
            onInput = nil
            onRemoved = nil
            if activeSendCount == 0 { tearDownIO() }
        }

        isolated deinit {
            if !isClosed { close() }
            if !ioTornDown { tearDownIO() }
        }

        private func received(_ frame: [UInt8]) {
            guard !isClosed else { return }
            onInput?(frame)
        }

        private func deviceWasRemoved() {
            guard !isClosed else { return }
            let callback = onRemoved
            close()
            callback?()
        }

        private func tearDownIO() {
            guard !ioTornDown else { return }
            ioTornDown = true
            IOHIDDeviceUnscheduleFromRunLoop(
                device, runLoop, CFRunLoopMode.commonModes.rawValue)
            if let inputBuffer {
                IOHIDDeviceRegisterInputReportCallback(
                    device, inputBuffer, inputBufferCapacity, nil, nil)
            }
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            IOHIDManagerClose(manager, 0)
            if let inputBuffer {
                inputBuffer.deinitialize(count: inputBufferCapacity)
                inputBuffer.deallocate()
                self.inputBuffer = nil
            }
        }
    }

    /// Safe under both callback orderings: IOKit may complete before or after
    /// the awaiting continuation has been installed.
    final class ReportSendOperation: @unchecked Sendable {
        let buffer: UnsafeMutablePointer<UInt8>
        let count: Int

        private let lock = NSLock()
        private var continuation: CheckedContinuation<IOReturn, Never>?
        private var completedResult: IOReturn?

        init(frame: [UInt8]) {
            count = frame.count
            buffer = .allocate(capacity: frame.count)
            frame.withUnsafeBufferPointer {
                buffer.initialize(from: $0.baseAddress!, count: frame.count)
            }
        }

        func install(_ continuation: CheckedContinuation<IOReturn, Never>) {
            lock.lock()
            if let completedResult {
                lock.unlock()
                continuation.resume(returning: completedResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ result: IOReturn) {
            lock.lock()
            guard completedResult == nil else {
                lock.unlock()
                return
            }
            completedResult = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }

        deinit {
            buffer.deinitialize(count: count)
            buffer.deallocate()
        }
    }
}
