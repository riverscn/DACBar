import Foundation
import AppKit
import Testing
@testable import ShanlingUA1II

@Suite("UA1 II hardware integration", .serialized)
@MainActor
struct HardwareIntegrationTests {

    @Test(
        "A no-op write is acknowledged even if ACK precedes output completion",
        .enabled(if: ProcessInfo.processInfo.environment["SHANLING_HARDWARE_TESTS"] == "1")
    )
    func noOpWriteIsAcknowledged() async throws {
        try await Task.sleep(for: .milliseconds(200))
        let connection = try hardwareConnection()
        defer { connection.close() }

        let state = try await connection.read()
        let write = try ShanlingUA1II.Write(.volume, UInt8(state.volume))
        var confirmed = false
        connection.onConfirmed = { received in
            if received == write { confirmed = true }
        }

        try await connection.submit(write)
        let deadline = ContinuousClock.now + .seconds(1)
        while !confirmed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(confirmed, "UA1 II did not acknowledge a no-op volume write")
    }

    @Test(
        "Changed writes are acknowledged and the original value is restored",
        .enabled(if: ProcessInfo.processInfo.environment["SHANLING_HARDWARE_TESTS"] == "1")
    )
    func changedWriteSequenceIsAcknowledged() async throws {
        try await Task.sleep(for: .milliseconds(200))
        let connection = try hardwareConnection()
        defer { connection.close() }

        let state = try await connection.read()
        let original = try ShanlingUA1II.Write(.brightness, UInt8(state.brightness))
        let alternateValue = state.brightness == 10 ? 9 : state.brightness + 1
        let alternate = try ShanlingUA1II.Write(.brightness, UInt8(alternateValue))
        var confirmations: [ShanlingUA1II.Write] = []
        connection.onConfirmed = { confirmations.append($0) }

        do {
            try await connection.submit(alternate)
            try await connection.submit(original)
        } catch {
            try? await connection.submit(original)
            throw error
        }

        let deadline = ContinuousClock.now + .seconds(2)
        while confirmations.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(confirmations.contains(alternate), "Changed brightness was not acknowledged")
        #expect(confirmations.contains(original), "Restored brightness was not acknowledged")
    }

    @Test(
        "Volume acknowledgement arrives while AppKit is tracking the mouse",
        .enabled(if: ProcessInfo.processInfo.environment["SHANLING_HARDWARE_TESTS"] == "1")
    )
    func volumeIsAcknowledgedInEventTrackingMode() async throws {
        try await Task.sleep(for: .milliseconds(200))
        let connection = try hardwareConnection()
        defer { connection.close() }

        let state = try await connection.read()
        let original = try ShanlingUA1II.Write(.volume, UInt8(state.volume))
        let alternateValue = state.volume == 99 ? 98 : state.volume + 1
        let alternate = try ShanlingUA1II.Write(.volume, UInt8(alternateValue))
        var confirmed = false
        var restored = false
        var confirmationMode: CFRunLoopMode?
        var reportIssued = false
        let trackingMode = CFRunLoopMode(
            rawValue: RunLoop.Mode.eventTracking.rawValue as CFString)
        connection.onConfirmed = { write in
            if write == alternate {
                confirmationMode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain())
                confirmed = true
            } else if write == original {
                restored = true
            }
        }
        connection.onReportIssuedForTesting = { reportIssued = true }

        let submission = Task { @MainActor in
            try await connection.submit(alternate)
        }
        do {
            let issueDeadline = ContinuousClock.now + .seconds(1)
            while !reportIssued, ContinuousClock.now < issueDeadline {
                await Task.yield()
            }
            #expect(reportIssued, "The asynchronous report was never issued")

            let deadline = Date(timeIntervalSinceNow: 1)
            while !confirmed, Date() < deadline {
                runEventTrackingSlice()
            }
            #expect(confirmed, "Volume ACK was starved in event-tracking run-loop mode")
            #expect(confirmationMode == trackingMode,
                    "Volume ACK was not delivered in event-tracking run-loop mode")
            try await submission.value
            try await connection.submit(original)
            let restoreDeadline = ContinuousClock.now + .seconds(1)
            while !restored, ContinuousClock.now < restoreDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(restored, "The original volume was not acknowledged")
        } catch {
            try? await connection.submit(original)
            throw error
        }
    }

    @Test(
        "Measure ACK reliability across completion intervals and restore the device",
        .enabled(if:
            ProcessInfo.processInfo.environment["SHANLING_HARDWARE_TESTS"] == "1"
            && ProcessInfo.processInfo.environment["SHANLING_SWEEP_INTERVALS"] != nil)
    )
    func completionIntervalSweep() async throws {
        let configuration = try SweepConfiguration()
        let locationID = try HardwareTarget.locationID()

        for interval in configuration.intervals {
            try await measure(
                intervalMilliseconds: interval,
                writeCount: configuration.writeCount,
                locationID: locationID)
        }
    }

    private func measure(
        intervalMilliseconds: Int,
        writeCount: Int,
        locationID: UInt32
    ) async throws {
        let connection = try ShanlingUA1II.Connection(locationID: locationID)
        defer { connection.close() }

        let initial = try await connection.read()
        let original = try ShanlingUA1II.Write(.brightness, UInt8(initial.brightness))
        let alternateValue = initial.brightness == 10 ? 9 : initial.brightness + 1
        let alternate = try ShanlingUA1II.Write(.brightness, UInt8(alternateValue))
        var confirmations = 0
        var drops = 0
        connection.onConfirmed = { _ in confirmations += 1 }
        connection.onDropped = { _ in drops += 1 }
        connection.minimumCompletionIntervalForTesting =
            .milliseconds(intervalMilliseconds)

        var stressError: (any Error)?
        var completions = 0
        do {
            for index in 0..<writeCount {
                try await connection.submit(
                    index.isMultiple(of: 2) ? alternate : original)
                completions += 1
            }
        } catch {
            stressError = error
        }

        let resultDeadline = ContinuousClock.now + .seconds(2)
        while confirmations + drops < writeCount,
              ContinuousClock.now < resultDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let stressConfirmations = confirmations
        let stressDrops = drops
        let expectedStressValue = writeCount.isMultiple(of: 2)
            ? Int(original.value) : Int(alternate.value)

        // From this point onward all I/O uses the production 130ms interval.
        connection.minimumCompletionIntervalForTesting = nil
        try await Task.sleep(for: .milliseconds(150))
        var stressBrightness: Int?
        var observationError: (any Error)?
        do {
            stressBrightness = try await connection.read().brightness
        } catch {
            observationError = error
        }

        let confirmationsBeforeRestore = confirmations
        var restoredBrightness: Int?
        var restorationError: (any Error)?
        do {
            try await connection.submit(original)
            let restoreDeadline = ContinuousClock.now + .seconds(1)
            while confirmations == confirmationsBeforeRestore,
                  ContinuousClock.now < restoreDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard confirmations > confirmationsBeforeRestore else {
                throw IntervalSweepFailure.restorationNotAcknowledged
            }
            restoredBrightness = try await connection.read().brightness
            guard restoredBrightness == Int(original.value) else {
                throw IntervalSweepFailure.restorationMismatch(
                    expected: Int(original.value), actual: restoredBrightness)
            }
        } catch {
            restorationError = error
        }

        let stressText = stressBrightness.map(String.init) ?? "unavailable"
        let restoredText = restoredBrightness.map(String.init) ?? "unavailable"

        print(
            "SHANLING_SWEEP "
                + "location=0x\(String(locationID, radix: 16, uppercase: true)) "
                + "interval_ms=\(intervalMilliseconds) writes=\(writeCount) "
                + "completions=\(completions) "
                + "acks=\(stressConfirmations) drops=\(stressDrops) "
                + "stress_brightness=\(stressText) "
                + "expected_stress=\(expectedStressValue) "
                + "restored_brightness=\(restoredText)")

        if let restorationError { throw restorationError }
        if let stressError { throw stressError }
        if let observationError { throw observationError }
    }

    private func hardwareConnection() throws -> ShanlingUA1II.Connection {
        try ShanlingUA1II.Connection(locationID: HardwareTarget.locationID())
    }

    private func runEventTrackingSlice() {
        _ = CFRunLoopRunInMode(
            CFRunLoopMode(rawValue:
                RunLoop.Mode.eventTracking.rawValue as CFString),
            0.02, true)
    }
}

private struct SweepConfiguration {
    let intervals: [Int]
    let writeCount: Int

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let rawIntervals = environment["SHANLING_SWEEP_INTERVALS"] else {
            throw HardwareTestConfigurationFailure.invalidSweep(
                "缺少 SHANLING_SWEEP_INTERVALS")
        }
        let pieces = rawIntervals.split(separator: ",", omittingEmptySubsequences: false)
        let parsed = pieces.compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        guard !parsed.isEmpty,
              parsed.count == pieces.count,
              parsed.allSatisfy({ (50...1_000).contains($0) }) else {
            throw HardwareTestConfigurationFailure.invalidSweep(
                "间隔必须是逗号分隔的 50...1000 毫秒整数")
        }
        let count = environment["SHANLING_SWEEP_COUNT"].flatMap(Int.init) ?? 40
        guard (2...500).contains(count) else {
            throw HardwareTestConfigurationFailure.invalidSweep(
                "SHANLING_SWEEP_COUNT 必须在 2...500 之间")
        }
        intervals = parsed
        writeCount = count
    }
}

private enum HardwareTarget {
    static func locationID(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        devices: [ShanlingUA1II.Device]? = nil
    ) throws -> UInt32 {
        let attached = try devices ?? ShanlingUA1II.devices()
        if let raw = environment["SHANLING_HARDWARE_LOCATION_ID"] {
            guard let requested = parseLocationID(raw) else {
                throw HardwareTestConfigurationFailure.invalidLocation(raw)
            }
            guard attached.contains(where: { $0.locationID == requested }) else {
                throw HardwareTestConfigurationFailure.locationNotFound(
                    requested, attached.map(\.locationID))
            }
            return requested
        }
        guard let only = attached.first else {
            throw HardwareTestConfigurationFailure.noDevice
        }
        guard attached.count == 1 else {
            throw HardwareTestConfigurationFailure.ambiguous(
                attached.map(\.locationID))
        }
        return only.locationID
    }

    private static func parseLocationID(_ raw: String) -> UInt32? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16)
        }
        return UInt32(trimmed, radix: 10)
    }
}

private enum HardwareTestConfigurationFailure: Error, LocalizedError {
    case noDevice
    case ambiguous([UInt32])
    case invalidLocation(String)
    case locationNotFound(UInt32, [UInt32])
    case invalidSweep(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "没有检测到受支持的真机"
        case .ambiguous(let locations):
            return "检测到多台设备（\(formatted(locations))）；请设置 SHANLING_HARDWARE_LOCATION_ID"
        case .invalidLocation(let raw):
            return "无法解析 SHANLING_HARDWARE_LOCATION_ID=\(raw)"
        case .locationNotFound(let requested, let locations):
            return "找不到 locationID \(hex(requested))；当前设备：\(formatted(locations))"
        case .invalidSweep(let message):
            return message
        }
    }

    private func formatted(_ values: [UInt32]) -> String {
        values.map(hex).joined(separator: ", ")
    }

    private func hex(_ value: UInt32) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }
}

private enum IntervalSweepFailure: Error, LocalizedError {
    case restorationNotAcknowledged
    case restorationMismatch(expected: Int, actual: Int?)

    var errorDescription: String? {
        switch self {
        case .restorationNotAcknowledged:
            return "恢复原亮度的写入没有收到 ACK"
        case .restorationMismatch(let expected, let actual):
            return "恢复原亮度失败：期望 \(expected)，实际 \(actual.map(String.init) ?? "无法读取")"
        }
    }
}

@Suite("Hardware test configuration")
struct HardwareTestConfigurationTests {
    @Test("Multiple devices require an explicit hardware location")
    func ambiguousHardwareTarget() throws {
        let first = device(locationID: 0x0110_0000)
        let second = device(locationID: 0x0210_0000)

        #expect(throws: HardwareTestConfigurationFailure.self) {
            _ = try HardwareTarget.locationID(
                environment: [:], devices: [first, second])
        }
        #expect(try HardwareTarget.locationID(
            environment: ["SHANLING_HARDWARE_LOCATION_ID": "0x02100000"],
            devices: [first, second]) == second.locationID)
    }

    @Test("Sweep configuration validates every interval and the write count")
    func sweepValidation() throws {
        let valid = try SweepConfiguration(environment: [
            "SHANLING_SWEEP_INTERVALS": "130, 127,126",
            "SHANLING_SWEEP_COUNT": "80",
        ])
        #expect(valid.intervals == [130, 127, 126])
        #expect(valid.writeCount == 80)

        #expect(throws: HardwareTestConfigurationFailure.self) {
            _ = try SweepConfiguration(environment: [
                "SHANLING_SWEEP_INTERVALS": "130,invalid",
            ])
        }
        #expect(throws: HardwareTestConfigurationFailure.self) {
            _ = try SweepConfiguration(environment: [
                "SHANLING_SWEEP_INTERVALS": "49",
            ])
        }
    }

    private func device(locationID: UInt32) -> ShanlingUA1II.Device {
        ShanlingUA1II.Device(
            profile: ShanlingUA1II.profile,
            productID: ShanlingUA1II.productID,
            locationID: locationID,
            registryEntryID: UInt64(locationID),
            name: "Shanling UA1 II")
    }
}
