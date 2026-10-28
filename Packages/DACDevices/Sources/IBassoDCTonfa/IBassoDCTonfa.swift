import CoreFoundation
import Foundation
import IOKit
import OSLog
import DACDeviceKit
import DACHIDTransport

/// HID control support for iBasso DC-Tonfa.
public enum IBassoDCTonfa {
    typealias Device = DACDeviceKit.Device
    typealias DeviceProfile = DACDeviceKit.DeviceProfile
    typealias DeviceRegistry = DACDeviceKit.DeviceRegistry

    static let modelID = DACDeviceKit.ModelID(rawValue: "ibasso.dc-tonfa")
    static let driverID = DACDeviceKit.DriverID(rawValue: "ibasso.dc-tonfa.hid")

    /// `0x6011` is listed by iBasso's WebHID console. Shipping hardware with
    /// firmware 1.66.39 enumerates as `0xF121`, with the same report descriptor.
    static let profile = DeviceProfile(
        id: modelID,
        displayName: "iBasso DC-Tonfa",
        productNames: ["iBasso DC-Tonfa", "DC-Tonfa"],
        hidMatches: [0x6011, 0xF121].map {
            DACDeviceKit.HIDMatch(
                vendorID: 0x2FC6,
                productID: $0,
                usagePage: 0x0C,
                usage: 0x01,
                inputReportSize: 8,
                outputReportSize: 8)
        },
        discoveryKind: .hidService,
        transportKind: .hidReports,
        driverID: driverID,
        verification: .verified(hardware: "DC-Tonfa", firmware: "1.66.39"))
    static let registry = try! DeviceRegistry(profiles: [profile])

    static let vendorID = 0x2FC6
    static let productIDs: Set<Int> = Set(profile.hidMatches.map(\.productID))
    static let outputReportID: CFIndex = 0
    private static let logger = Logger(
        subsystem: "IBassoDCTonfa", category: "transport")

    enum Failure: Error, LocalizedError {
        case managerFailed(IOReturn)
        case deviceNotFound
        case sendFailed(IOReturn)
        case timedOut
        case removed
        case invalidFrame
        case invalidValue(Setting)
        case stateUnavailable

        var errorDescription: String? {
            switch self {
            case .managerFailed(let result):
                return TonfaL10n.format(
                    "error.hid-unavailable",
                    defaultValue: "Unable to access the HID subsystem (0x%08X).",
                    UInt32(bitPattern: result))
            case .deviceNotFound:
                return TonfaL10n.text(
                    "error.device-not-found", defaultValue: "Device not found.")
            case .sendFailed(let result):
                return TonfaL10n.format(
                    "error.write-failed",
                    defaultValue: "Write failed (0x%08X).",
                    UInt32(bitPattern: result))
            case .timedOut:
                return TonfaL10n.text(
                    "error.device-timeout", defaultValue: "The device did not respond.")
            case .removed:
                return TonfaL10n.text(
                    "error.device-removed", defaultValue: "The device was disconnected.")
            case .invalidFrame:
                return TonfaL10n.text(
                    "error.invalid-frame", defaultValue: "The device returned invalid data.")
            case .invalidValue:
                return TonfaL10n.text(
                    "error.invalid-wire-value", defaultValue: "The setting value is invalid.")
            case .stateUnavailable:
                return TonfaL10n.text(
                    "error.state-unavailable",
                    defaultValue: "Read the device state before changing this setting.")
            }
        }
    }

    // MARK: - Enumeration

    static func devices() throws -> [Device] {
        do {
            return try DACHIDTransport.DeviceDiscovery.devices(in: registry)
        } catch DACHIDTransport.Failure.managerFailed(let result) {
            throw Failure.managerFailed(result)
        }
    }

    // MARK: - Connection

    @MainActor
    final class Connection {
        var onChange: ((Setting) -> Void)?
        var onConfirmed: ((Setting) -> Void)?
        var onRemoved: (() -> Void)?

        private static let responseTimeout: Duration = .milliseconds(500)
        private static let sendTimeoutMilliseconds: CFTimeInterval = 500

        private struct FrameWaiter {
            let id: Int
            let section: Section
            let continuation: CheckedContinuation<[UInt8], any Error>
            let timeoutTask: Task<Void, Never>
        }

        private struct GateWaiter {
            let continuation: CheckedContinuation<Void, any Error>
        }

        private let session: DACHIDTransport.ReportSession
        private var closed = false
        private var transactionBusy = false
        private var transactionWaiters: [GateWaiter] = []
        private var waiter: FrameWaiter?
        private var nextWaiterID = 0
        private var backlog: [[UInt8]] = []
        private var state = State()

        init(device expected: Device) throws {
            guard expected.profile == IBassoDCTonfa.profile else {
                throw Failure.deviceNotFound
            }
            do {
                session = try DACHIDTransport.ReportSession(
                    device: expected, registry: IBassoDCTonfa.registry)
            } catch DACHIDTransport.Failure.managerFailed(let result) {
                throw Failure.managerFailed(result)
            } catch DACHIDTransport.Failure.deviceNotFound {
                throw Failure.deviceNotFound
            }

            session.onInput = { [weak self] frame in self?.received(frame) }
            session.onRemoved = { [weak self] in self?.deviceWasRemoved() }
        }

        func close() {
            guard !closed else { return }
            closed = true
            finishWaiter(id: waiter?.id, result: .failure(Failure.removed))
            for waiter in transactionWaiters {
                waiter.continuation.resume(throwing: Failure.removed)
            }
            transactionWaiters.removeAll()
            backlog.removeAll()
            onChange = nil
            onConfirmed = nil
            onRemoved = nil
            session.close()
        }

        isolated deinit {
            if !closed { close() }
        }

        func read() async throws -> State {
            try await acquireTransaction()
            defer { releaseTransaction() }
            try Task.checkCancellation()
            backlog.removeAll()

            var snapshot = State()
            for section in Section.allCases {
                try await issue(TonfaWireCodec.query(section))
                let reply = try await waitForFrame(section: section)
                try TonfaWireCodec.apply(reply, to: &snapshot)
            }
            snapshot.valid = true
            state = snapshot
            return snapshot
        }

        func submit(_ setting: Setting) async throws {
            try await acquireTransaction()
            defer { releaseTransaction() }
            guard state.valid else { throw Failure.stateUnavailable }
            let frame = try TonfaWireCodec.encode(setting, state: state)
            try await issue(frame)
            state.apply(setting)
            onConfirmed?(setting)
        }

        private func received(_ frame: [UInt8]) {
            guard !closed, frame.count == TonfaWireCodec.reportLength else { return }
            guard let section = TonfaWireCodec.section(of: frame) else { return }
            if let waiter, waiter.section == section {
                finishWaiter(id: waiter.id, result: .success(frame))
                return
            }
            backlog.append(frame)
            if backlog.count > 10 { backlog.removeFirst(backlog.count - 10) }

            guard state.valid else { return }
            var updated = state
            do {
                try TonfaWireCodec.apply(frame, to: &updated)
            } catch {
                Self.logMalformedFrame()
                return
            }
            let changes = state.changes(to: updated)
            state = updated
            for change in changes { onChange?(change) }
        }

        private nonisolated static func logMalformedFrame() {
            IBassoDCTonfa.logger.error("Discarded malformed input report")
        }

        private func waitForFrame(section: Section) async throws -> [UInt8] {
            if let index = backlog.firstIndex(where: {
                TonfaWireCodec.section(of: $0) == section
            }) {
                return backlog.remove(at: index)
            }
            guard !closed else { throw Failure.removed }
            nextWaiterID += 1
            let id = nextWaiterID
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let timeoutTask = Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(for: Self.responseTimeout)
                        } catch {
                            return
                        }
                        self?.finishWaiter(id: id, result: .failure(Failure.timedOut))
                    }
                    waiter = FrameWaiter(
                        id: id, section: section,
                        continuation: continuation, timeoutTask: timeoutTask)
                    if Task<Never, Never>.isCancelled {
                        finishWaiter(id: id, result: .failure(CancellationError()))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.finishWaiter(id: id, result: .failure(CancellationError()))
                }
            }
        }

        private func finishWaiter(id: Int?, result: Result<[UInt8], any Error>) {
            guard let id, let waiter, waiter.id == id else { return }
            self.waiter = nil
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(with: result)
        }

        private func acquireTransaction() async throws {
            guard !closed else { throw Failure.removed }
            if !transactionBusy {
                transactionBusy = true
                return
            }
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !closed else {
                    continuation.resume(throwing: Failure.removed)
                    return
                }
                transactionWaiters.append(GateWaiter(continuation: continuation))
            }
        }

        private func releaseTransaction() {
            if closed || transactionWaiters.isEmpty {
                transactionBusy = false
            } else {
                transactionWaiters.removeFirst().continuation.resume()
            }
        }

        private func issue(_ frame: [UInt8]) async throws {
            try Task.checkCancellation()
            guard !closed else { throw Failure.removed }
            let result = await sendReport(frame)
            try Task.checkCancellation()
            guard !closed else { throw Failure.removed }
            guard result == kIOReturnSuccess else { throw Failure.sendFailed(result) }
        }

        private func sendReport(_ frame: [UInt8]) async -> IOReturn {
            await session.send(
                frame,
                reportID: IBassoDCTonfa.outputReportID,
                timeoutMilliseconds: Self.sendTimeoutMilliseconds)
        }

        private func deviceWasRemoved() {
            guard !closed else { return }
            let callback = onRemoved
            close()
            callback?()
        }

    }
}
