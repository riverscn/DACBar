import Foundation
import Testing
@testable import IBassoDCTonfa

@Suite(
    "iBasso DC-Tonfa hardware",
    .enabled(if: ProcessInfo.processInfo.environment["IBASSO_TONFA_HARDWARE_TESTS"] == "1")
)
@MainActor
struct HardwareIntegrationTests {
    @Test("Read all settings from attached hardware")
    func readState() async throws {
        let device = try #require(try IBassoDCTonfa.devices().single)
        let connection = try IBassoDCTonfa.Connection(device: device)
        defer { connection.close() }

        let state = try await connection.read()
        #expect(state.valid)
        #expect((0...100).contains(state.volume))
        #expect((0...4).contains(state.filter))
        #expect((0...2).contains(state.gain))
        #expect((-10...10).contains(state.balance))
        #expect((0...1).contains(state.coaxialOutput))
        #expect((0...1).contains(state.keyControl))
        #expect((0...3).contains(state.screenTimeout))
        #expect((0...1).contains(state.orientation))
        #expect(!state.firmware.isEmpty)
    }

    @Test("A no-op screen write completes and reads back without changing state")
    func noOpWrite() async throws {
        let device = try #require(try IBassoDCTonfa.devices().single)
        let connection = try IBassoDCTonfa.Connection(device: device)
        defer { connection.close() }

        let before = try await connection.read()
        try await connection.submit(.screenTimeout(before.screenTimeout))
        let after = try await connection.read()

        #expect(after == before)
    }
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}
