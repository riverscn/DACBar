import Testing
@testable import ShanlingUA1II

@Suite("Shanling vendor protocol")
struct ShanlingUA1IITests {

    @Test("The asynchronous IOKit call uses the UA1 II hardware-tested report ID")
    func asynchronousReportID() {
        #expect(ShanlingUA1II.outputReportID == 0)
    }

    @Test("Output frames contain report ID and a valid payload checksum")
    func outputFrame() {
        let frame = ShanlingUA1II.wireFrame(command: 0x01, value: 40)

        #expect(frame.count == 41)
        #expect(frame[0] == 0x01)
        #expect(Array(frame[1...6]) == [0xAA, 0x55, 0x10, 0x01, 40, 0x01])
        let sum = frame[1..<40].reduce(0) { $0 + Int($1) }
        #expect(frame[40] == UInt8(~sum & 0xFF))
    }

    @Test("Reply validation checks report ID, header, length, and checksum")
    func replyValidation() {
        let valid = reply(page: 0x21, bytes: [27, 1, 3, 0xF7])
        #expect(ShanlingUA1II.isValidReplyFrame(valid))

        var wrongID = valid
        wrongID[0] = 0x02
        #expect(!ShanlingUA1II.isValidReplyFrame(wrongID))

        var wrongChecksum = valid
        wrongChecksum[8] &+= 1
        #expect(!ShanlingUA1II.isValidReplyFrame(wrongChecksum))

        #expect(!ShanlingUA1II.isValidReplyFrame(Array(valid.dropLast())))
    }

    @Test("Captured UA1 II state pages decode into one complete state")
    func capturedStatePages() throws {
        // Captured from the physical UA1 II and documented in
        // Documentation/ShanlingUA1II/ProtocolFindings.md.
        let captured: [[UInt8]] = [
            [0x01, 0x55, 0xAA, 0x20, 0x01, 0x00, 0x00, 0x00, 0xDF],
            [0x01, 0x55, 0xAA, 0x21, 0x1B, 0x00, 0x01, 0x00, 0xC3],
            [0x01, 0x55, 0xAA, 0x22, 0x06, 0x00, 0x00, 0x00, 0xD8],
            [0x01, 0x55, 0xAA, 0x23, 0x34, 0x00, 0x00, 0x00, 0xA9],
        ]
        var state = ShanlingUA1II.State()

        for frame in captured {
            try ShanlingUA1II.UA1IIWireCodec.applyStatePage(frame, to: &state)
        }

        #expect(state.firmware == "01.00.00")
        #expect(state.volume == 27)
        #expect(state.gain == 0)
        #expect(state.filter == 1)
        #expect(state.balance == 0)
        #expect(state.brightness == 6)
        #expect(state.screenTimeout == 0)
        #expect(state.orientation == 0)
        #expect(state.screenOffset == 2)
    }

    @Test("Input decoding distinguishes acknowledgements and terminators")
    func inputClassification() throws {
        let acknowledgement = reply(page: 0x10, bytes: [0x01, 0x14, 0x00, 0x00])
        let expected = try ShanlingUA1II.Write(.volume, 20)
        let terminator: [UInt8] = [0x01, 0, 0, 0, 0, 0, 0, 0, 0]

        #expect(try ShanlingUA1II.UA1IIWireCodec.decode(acknowledgement)
                == .acknowledgement(expected))
        #expect(try ShanlingUA1II.UA1IIWireCodec.decode(terminator) == .terminator)
        #expect(!ShanlingUA1II.UA1IIWireCodec.isValidDataFrame(terminator))
    }

    @Test("Well-framed reports still reject unknown pages and invalid field values")
    func semanticReplyValidation() throws {
        let unknownPage = reply(page: 0x24, bytes: [0, 0, 0, 0])
        let invalidAudio = reply(page: 0x21, bytes: [100, 0, 0, 0])
        let invalidAcknowledgement = reply(page: 0x10, bytes: [0x05, 0, 0, 0])
        var state = ShanlingUA1II.State()

        #expect(throws: ShanlingUA1II.Failure.self) {
            _ = try ShanlingUA1II.UA1IIWireCodec.decode(unknownPage)
        }
        #expect(throws: ShanlingUA1II.Failure.self) {
            try ShanlingUA1II.UA1IIWireCodec.applyStatePage(invalidAudio, to: &state)
        }
        #expect(throws: ShanlingUA1II.Failure.self) {
            _ = try ShanlingUA1II.UA1IIWireCodec.decode(invalidAcknowledgement)
        }
    }

    @Test("Typed writes reject values outside each command's wire range")
    func typedWriteValidation() throws {
        #expect(throws: Never.self) {
            _ = try ShanlingUA1II.Write(.volume, 99)
            _ = try ShanlingUA1II.Write(.balance, UInt8(bitPattern: -12))
            _ = try ShanlingUA1II.Write(.screenOffset, 60)
        }
        #expect(throws: ShanlingUA1II.Failure.self) {
            _ = try ShanlingUA1II.Write(.volume, 100)
        }
        #expect(throws: ShanlingUA1II.Failure.self) {
            _ = try ShanlingUA1II.Write(.balance, UInt8(bitPattern: -13))
        }
        #expect(throws: ShanlingUA1II.Failure.self) {
            _ = try ShanlingUA1II.Write(.screenOffset, 49)
        }
    }

    @Test("A timed-out write only consumes a matching late ACK within its grace window")
    func lateAcknowledgementGraceWindow() throws {
        let write = try ShanlingUA1II.Write(.volume, 21)
        let other = try ShanlingUA1II.Write(.volume, 22)
        let start = ContinuousClock.now
        var acknowledgements = ShanlingUA1II.LateAcknowledgements(
            retention: .seconds(2))

        acknowledgements.remember(write, now: start)
        let consumedOther = acknowledgements.consume(
            other, now: start + .milliseconds(10))
        let consumedWrite = acknowledgements.consume(
            write, now: start + .milliseconds(20))
        let consumedTwice = acknowledgements.consume(
            write, now: start + .milliseconds(30))
        #expect(!consumedOther)
        #expect(consumedWrite)
        #expect(!consumedTwice)

        acknowledgements.remember(write, now: start)
        let consumedExpired = acknowledgements.consume(
            write, now: start + .seconds(2))
        #expect(!consumedExpired)
    }

    private func reply(page: UInt8, bytes: [UInt8]) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 9)
        frame[0] = 0x01
        frame[1] = 0x55
        frame[2] = 0xAA
        frame[3] = page
        for (offset, value) in bytes.prefix(4).enumerated() {
            frame[4 + offset] = value
        }
        let sum = frame[1..<8].reduce(0) { $0 + Int($1) }
        frame[8] = UInt8(~sum & 0xFF)
        return frame
    }
}
