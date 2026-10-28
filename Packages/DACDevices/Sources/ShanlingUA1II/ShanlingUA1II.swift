import CoreFoundation
import Foundation
import IOKit
import OSLog
import DACDeviceKit
import DACHIDTransport

/// Vendor-channel access for the Shanling UA1 II.
///
/// Everything goes through the HID driver macOS already has attached to
/// interface 2: settings are written as output reports, state comes back as
/// input reports, and the device volunteers an input report of its own whenever
/// its physical buttons change something. No privileges, no exclusive access,
/// and audio is never interrupted.
///
/// The one detail that makes it work: **the buffer handed to
/// `IOHIDDeviceSetReportWithCallback` must carry the report ID itself** — 41
/// bytes starting with 0x01. IOKit sends it verbatim and does not prepend the ID
/// for you, so a 40-byte payload arrives with 0xAA where the ID belongs and the
/// firmware discards it. The `reportID` argument is not what decides this for
/// the synchronous API: 0 and 1 both work as long as the buffer is right. This
/// implementation passes 0 because that is the value verified with the
/// asynchronous IOKit API on UA1 II hardware.
///
/// Getting that wrong is quiet in both directions — writes have no effect and
/// queries go unanswered — which reads as "this channel is unusable" and once
/// sent the project down a path of capturing the device with root privileges.
/// See Documentation/ShanlingUA1II/ProtocolFindings.md.
public enum ShanlingUA1II {

    typealias Device = DACDeviceKit.Device
    typealias DeviceProfile = DACDeviceKit.DeviceProfile
    typealias DeviceRegistry = DACDeviceKit.DeviceRegistry
    typealias ModelID = DACDeviceKit.ModelID

    static let modelID = ModelID(rawValue: "shanling.ua1-ii")
    static let driverID = DACDeviceKit.DriverID(
        rawValue: "shanling.ua1-ii.hid")
    static let profile = DeviceProfile(
        id: modelID,
        displayName: "Shanling UA1 II",
        productNames: ["Shanling UA1 II", "UA1 II", "UA1 2nd Gen"],
        hidMatches: [
            DACDeviceKit.HIDMatch(
                vendorID: 0x20B1,
                productID: 0x3033,
                usagePage: 0x01,
                usage: 0x80,
                inputReportSize: 9,
                outputReportSize: 41)
        ],
        discoveryKind: .hidService,
        transportKind: .hidReports,
        driverID: driverID,
        verification: .verified(hardware: "UA1 II", firmware: nil))
    static let registry = try! DeviceRegistry(profiles: [profile])

    static let vendorID = profile.hidMatches[0].vendorID
    static let productID = profile.hidMatches[0].productID
    private static let logger = Logger(subsystem: "ShanlingUA1II", category: "transport")

    /// Screen offset is the one field whose wire value differs from the logical
    /// one.
    static let screenOffsetBias = 50

    /// UA1 II requires zero here when using the asynchronous IOKit API even
    /// though byte zero of the report buffer still carries report ID 0x01.
    /// Passing 1 completes successfully but the device never answers.
    static let outputReportID: CFIndex = 0

    // MARK: - Protocol surface

    /// Command bytes, all verified against real UA1 II hardware.
    enum Command: UInt8, Sendable, CaseIterable, Hashable {
        case volume        = 0x01
        case gain          = 0x02
        case filter        = 0x03
        case balance       = 0x04
        case brightness    = 0x06
        case orientation   = 0x07
        case screenTimeout = 0x09
        case screenOffset  = 0x15

        func accepts(_ value: UInt8) -> Bool {
            switch self {
            case .volume:        return value <= 99
            case .gain:          return value <= 1
            case .filter:        return value <= 4
            case .balance:       return (-12...12).contains(Int(Int8(bitPattern: value)))
            case .brightness:    return value <= 10
            case .orientation:   return value <= 3
            case .screenTimeout: return value <= 60
            case .screenOffset:  return (50...60).contains(value)
            }
        }
    }

    struct Write: Sendable, Equatable, Hashable {
        let command: Command
        /// Already in wire units.
        let value: UInt8

        init(_ command: Command, _ value: UInt8) throws {
            guard command.accepts(value) else {
                throw Failure.invalidValue(command, value)
            }
            self.command = command
            self.value = value
        }
    }

    struct State: Equatable, Sendable {
        var valid = false
        var volume = 0          // 0–99
        var gain = 0            // 0 low, 1 high
        var filter = 0          // 0–4
        var balance = 0         // −12…12, signed on the wire
        var brightness = 0      // 0–10
        var screenTimeout = 0   // seconds, 0 = never
        var orientation = 0     // 0–3
        var screenOffset = 0    // 0–10, stored as value + 50
        var firmware = ""

        init() {}

        /// Applies one validated `0x10` acknowledgement — how a button press on
        /// the device reaches us.
        mutating func apply(_ write: Write) {
            let value = write.value
            switch write.command {
            case .volume:        volume = Int(value)
            case .gain:          gain = Int(value)
            case .filter:        filter = Int(value)
            case .balance:       balance = Int(Int8(bitPattern: value))
            case .brightness:    brightness = Int(value)
            case .orientation:   orientation = Int(value)
            case .screenTimeout: screenTimeout = Int(value)
            case .screenOffset:  screenOffset = Int(value) - screenOffsetBias
            }
        }
    }

    enum Failure: Error, LocalizedError {
        case managerFailed(IOReturn)
        case deviceNotFound
        case sendFailed(IOReturn)
        case timedOut
        case removed
        case invalidFrame
        case invalidValue(Command, UInt8)

        var errorDescription: String? {
            switch self {
            case .managerFailed(let r):
                return DeviceL10n.format(
                    "error.hid-unavailable",
                    defaultValue: "Unable to access the HID subsystem (0x%08X).",
                    UInt32(bitPattern: r))
            case .deviceNotFound:
                return DeviceL10n.text("error.device-not-found", defaultValue: "Device not found.")
            case .sendFailed(let r):
                return DeviceL10n.format(
                    "error.write-failed",
                    defaultValue: "Write failed (0x%08X).",
                    UInt32(bitPattern: r))
            case .timedOut:
                return DeviceL10n.text("error.device-timeout", defaultValue: "The device did not respond.")
            case .removed:
                return DeviceL10n.text("error.device-removed", defaultValue: "The device was disconnected.")
            case .invalidFrame:
                return DeviceL10n.text("error.invalid-frame", defaultValue: "The device returned invalid data.")
            case .invalidValue(let command, let value):
                return DeviceL10n.format(
                    "error.invalid-wire-value",
                    defaultValue: "Value 0x%02X is outside the range for command 0x%02X.",
                    value, command.rawValue)
            }
        }
    }

    // MARK: - Enumeration

    /// Every attached dongle.
    static func devices() throws -> [Device] {
        do {
            return try DACHIDTransport.DeviceDiscovery.devices(in: registry)
        } catch DACHIDTransport.Failure.managerFailed(let result) {
            throw Failure.managerFailed(result)
        }
    }

    // MARK: - Session

    /// An open connection to one dongle: writes settings, reads state, and
    /// reports changes made on the device itself.
    ///
    /// Deliberately long-lived. Input reports only arrive while the device is
    /// scheduled on a run loop, and it is that stream — not polling — that keeps
    /// the app in step with the dongle's own buttons.
    ///
    /// Main-actor bound: the callback is delivered on the run loop of whichever
    /// thread created the connection, and everything here waits by suspending
    /// rather than by blocking that thread.
    @MainActor
    final class Connection {

        var onChange: ((Write) -> Void)?
        var onConfirmed: ((Write) -> Void)?
        var onDropped: ((Write) -> Void)?
        var onRemoved: (() -> Void)?
#if DEBUG
        /// Test synchronization point immediately after IOKit accepts an
        /// asynchronous report request. Not part of the public API surface.
        var onReportIssuedForTesting: (() -> Void)?
        /// Opt-in hardware characterization only. Production always uses the
        /// measured 130ms completion-to-next-send interval below.
        var minimumCompletionIntervalForTesting: Duration?
#endif

        // The device's measured hard edge is 130ms. For the callback API this
        // interval starts only after IOKit reports that the preceding output
        // completed—not when the asynchronous call was initiated.
        private static let minimumInterval: Duration = .milliseconds(130)
        private static let ackTimeout: Duration = .milliseconds(400)
        private static let settleInterval: Duration = .milliseconds(120)
        private static let sendTimeoutMilliseconds: CFTimeInterval = 500

        private struct FrameWaiter {
            let id: Int
            let matches: ([UInt8]) -> Bool
            let continuation: CheckedContinuation<[UInt8], any Error>
            let timeoutTask: Task<Void, Never>
        }

        private struct GateWaiter {
            let continuation: CheckedContinuation<Void, any Error>
        }

        private let session: DACHIDTransport.ReportSession
        private var closed = false
        private var lastSend: ContinuousClock.Instant?

        private var transactionBusy = false
        private var transactionWaiters: [GateWaiter] = []
        private var waiter: FrameWaiter?
        private var nextWaiterID = 0
        private var backlog: [[UInt8]] = []

        private var acknowledgementSession = AcknowledgementSession(
            debtRetention: .seconds(2))
        private var acknowledgementTimeouts: [
            AcknowledgementSession.SubmissionID: Task<Void, Never>
        ] = [:]

        init(device expected: Device) throws {
            let profile = expected.profile
            guard profile == ShanlingUA1II.profile else {
                throw Failure.deviceNotFound
            }
            do {
                session = try DACHIDTransport.ReportSession(
                    device: expected, registry: ShanlingUA1II.registry)
            } catch DACHIDTransport.Failure.managerFailed(let result) {
                throw Failure.managerFailed(result)
            } catch DACHIDTransport.Failure.deviceNotFound {
                throw Failure.deviceNotFound
            }

            session.onInput = { [weak self] frame in self?.received(frame) }
            session.onRemoved = { [weak self] in self?.deviceWasRemoved() }
#if DEBUG
            session.onReportIssuedForTesting = { [weak self] in
                self?.onReportIssuedForTesting?()
            }
#endif
        }

        /// Explicit and idempotent because HID callbacks hold an unretained
        /// context and their lifetime must end before the input buffer is freed.
        func close() {
            guard !closed else { return }
            closed = true

            finishWaiter(id: waiter?.id, result: .failure(Failure.removed))
            for gateWaiter in transactionWaiters {
                gateWaiter.continuation.resume(throwing: Failure.removed)
            }
            transactionWaiters.removeAll()
            for task in acknowledgementTimeouts.values { task.cancel() }
            acknowledgementTimeouts.removeAll()
            acknowledgementSession.removeAll()
            backlog.removeAll()

            onChange = nil
            onConfirmed = nil
            onDropped = nil
            onRemoved = nil
            session.close()
        }

        isolated deinit {
            if !closed { close() }
        }

        private func deviceWasRemoved() {
            guard !closed else { return }
            let removalHandler = onRemoved
            close()
            removalHandler?()
        }

        // MARK: Input reports

        private func received(_ frame: [UInt8]) {
            guard !closed else { return }
            guard frame.count == UA1IIWireCodec.inputReportLength else { return }
            let input: UA1IIWireCodec.Input
            do {
                input = try UA1IIWireCodec.decode(frame)
            } catch {
                if frame.count >= 3, frame[1] == 0x55, frame[2] == 0xAA {
                    ShanlingUA1II.logger.error("Discarded malformed input report")
                }
                return
            }

            switch input {
            case .terminator:
                return
            case .statePage:
                if let waiter, waiter.matches(frame) {
                    finishWaiter(id: waiter.id, result: .success(frame))
                } else {
                    backlog.append(frame)
                    if backlog.count > 8 { backlog.removeFirst(backlog.count - 8) }
                }
            case .acknowledgement(let write):
                switch acknowledgementSession.acknowledge(write) {
                case .confirmed(let id, _):
                    acknowledgementTimeouts.removeValue(forKey: id)?.cancel()
                    ShanlingUA1II.logger.debug(
                        "ACK matched id=\(id, privacy: .public) command=\(write.command.rawValue, privacy: .public) value=\(write.value, privacy: .public)")
                    onConfirmed?(write)
                case .ignoredLate(let id, _):
                    ShanlingUA1II.logger.info(
                        "Ignored late ACK for dropped id=\(id, privacy: .public) command=\(write.command.rawValue, privacy: .public) value=\(write.value, privacy: .public)")
                case .unmatched:
                    ShanlingUA1II.logger.info(
                        "Unmatched ACK treated as device change command=\(write.command.rawValue, privacy: .public) value=\(write.value, privacy: .public)")
                    onChange?(write)
                }
            }
        }

        private func waitForFrame(matching matches: @escaping ([UInt8]) -> Bool,
                                  timeout: Duration) async throws -> [UInt8] {
            if let index = backlog.firstIndex(where: matches) {
                return backlog.remove(at: index)
            }
            guard !closed else { throw Failure.removed }

            nextWaiterID += 1
            let id = nextWaiterID
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let timeoutTask = Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(for: timeout)
                        } catch {
                            return
                        }
                        self?.finishWaiter(id: id, result: .failure(Failure.timedOut))
                    }
                    waiter = FrameWaiter(id: id, matches: matches,
                                         continuation: continuation,
                                         timeoutTask: timeoutTask)
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

        // MARK: Transaction gate

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
            if closed {
                transactionBusy = false
                return
            }
            if transactionWaiters.isEmpty {
                transactionBusy = false
            } else {
                transactionWaiters.removeFirst().continuation.resume()
            }
        }

        // MARK: Writing

        /// Submits one setting write. Acknowledgement remains asynchronous so a
        /// missing intermediate slider value never stalls later values.
        func submit(_ write: Write) async throws {
            try await acquireTransaction()
            defer { releaseTransaction() }
            try Task.checkCancellation()
            try await pace()

            // Reserve before the asynchronous output call. The device can send
            // its acknowledgement before IOKit invokes the output completion;
            // registering afterwards misclassifies that ACK as a physical
            // change and then waits forever for a second one.
            let id = reserve(write)
            do {
                try await issue(command: write.command.rawValue, value: write.value)
                armTimeout(id: id)
            } catch {
                discardOutstanding(id: id)
                throw error
            }
        }

        private func reserve(_ write: Write) -> Int {
            let id = acknowledgementSession.reserve(write)
            ShanlingUA1II.logger.debug(
                "Reserved ACK id=\(id, privacy: .public) command=\(write.command.rawValue, privacy: .public) value=\(write.value, privacy: .public)")
            return id
        }

        private func armTimeout(id: Int) {
            guard acknowledgementSession.contains(id) else {
                // The ACK arrived while the asynchronous output call was still
                // awaiting its completion callback.
                return
            }
            let timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: Self.ackTimeout)
                } catch {
                    return
                }
                guard let self,
                      let dropped = self.acknowledgementSession.timeout(id)
                else { return }
                self.acknowledgementTimeouts.removeValue(forKey: id)
                ShanlingUA1II.logger.error(
                    "ACK timed out id=\(id, privacy: .public) command=\(dropped.command.rawValue, privacy: .public) value=\(dropped.value, privacy: .public)")
                self.onDropped?(dropped)
            }
            acknowledgementTimeouts[id] = timeoutTask
        }

        private func discardOutstanding(id: Int) {
            acknowledgementSession.cancel(id)
            acknowledgementTimeouts.removeValue(forKey: id)?.cancel()
        }

        private func pace() async throws {
            try Task.checkCancellation()
            let minimumInterval: Duration
#if DEBUG
            minimumInterval = minimumCompletionIntervalForTesting
                ?? Self.minimumInterval
#else
            minimumInterval = Self.minimumInterval
#endif
            if let lastSend {
                let elapsed = ContinuousClock.now - lastSend
                if elapsed < minimumInterval {
                    try await Task.sleep(for: minimumInterval - elapsed)
                }
            }
            try Task.checkCancellation()
            guard !closed else { throw Failure.removed }
        }

        private func send(command: UInt8, value: UInt8) async throws {
            try await pace()
            try await issue(command: command, value: value)
        }

        private func issue(command: UInt8, value: UInt8) async throws {
            let frame = ShanlingUA1II.wireFrame(command: command, value: value)
            let result = await sendReport(frame)
            // Callback completion is the first reliable boundary after the
            // report has been issued. Pacing from API invocation made two
            // physical writes much closer than the nominal interval whenever
            // IOKit spent time queueing the first one.
            lastSend = ContinuousClock.now
            ShanlingUA1II.logger.debug(
                "Output completed command=\(command, privacy: .public) value=\(value, privacy: .public) result=\(result, privacy: .public)")
            try Task.checkCancellation()
            guard !closed else { throw Failure.removed }
            guard result == kIOReturnSuccess else { throw Failure.sendFailed(result) }
        }

        private func sendReport(_ frame: [UInt8]) async -> IOReturn {
            await session.send(
                frame,
                reportID: ShanlingUA1II.outputReportID,
                timeoutMilliseconds: Self.sendTimeoutMilliseconds)
        }

        // MARK: Reading

        /// Queries all four state pages as one indivisible transaction.
        func read() async throws -> State {
            try await acquireTransaction()
            defer { releaseTransaction() }
            try Task.checkCancellation()
            backlog.removeAll()

            var state = State()
            for page in UInt8(0)..<4 {
                try await send(command: 0xFF, value: page)
                let expected = UInt8(0x20) + page
                let reply = try await waitForFrame(
                    matching: { $0[3] == expected },
                    timeout: Self.ackTimeout)
                try await Task.sleep(for: Self.settleInterval)
                try UA1IIWireCodec.applyStatePage(reply, to: &state)
            }
            state.valid = true
            return state
        }
    }

    // MARK: - Framing

    /// The complete 41-byte interrupt-OUT frame: report ID 0x01, then the
    /// payload — checksum is the complement of the payload's byte sum.
    static func wireFrame(command: UInt8, value: UInt8) -> [UInt8] {
        UA1IIWireCodec.encode(command: command, value: value)
    }

    static func isValidReplyFrame(_ frame: [UInt8]) -> Bool {
        UA1IIWireCodec.isValidDataFrame(frame)
    }
}
