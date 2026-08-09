import Foundation
import DACDeviceKit

extension ShanlingUA1II {
    /// Pure UA1 II report framing and parsing.
    ///
    /// This deliberately knows nothing about IOHID, pacing, callbacks, or
    /// connection lifetime. Keeping the wire format here lets captured reports
    /// exercise the protocol without changing the hardware-tested transport.
    enum UA1IIWireCodec {
        static let outputReportLength = 41
        static let inputReportLength = 9

        enum Page: UInt8, Equatable, Sendable {
            case version = 0x20
            case audio = 0x21
            case display = 0x22
            case offset = 0x23
            case acknowledgement = 0x10
        }

        enum Input: Equatable, Sendable {
            case terminator
            case statePage(Page)
            case acknowledgement(Write)
        }

        /// The complete interrupt-OUT report, including report ID `0x01`.
        static func encode(command: UInt8, value: UInt8) -> [UInt8] {
            var frame = [UInt8](repeating: 0, count: outputReportLength)
            frame[0] = 0x01
            frame[1] = 0xAA
            frame[2] = 0x55
            frame[3] = 0x10
            frame[4] = command
            frame[5] = value
            frame[6] = 0x01
            frame[outputReportLength - 1] = checksum(
                frame[1..<(outputReportLength - 1)])
            return frame
        }

        /// Classifies a complete input report after validating its framing.
        static func decode(_ frame: [UInt8]) throws -> Input {
            if isTerminator(frame) { return .terminator }
            guard isValidDataFrame(frame),
                  let page = Page(rawValue: frame[3]) else {
                throw Failure.invalidFrame
            }
            guard page == .acknowledgement else { return .statePage(page) }
            guard let command = Command(rawValue: frame[4]),
                  let write = try? Write(command, frame[5]) else {
                throw Failure.invalidFrame
            }
            return .acknowledgement(write)
        }

        /// Merges one validated state page into the in-progress snapshot.
        static func applyStatePage(_ frame: [UInt8], to state: inout State) throws {
            guard case .statePage(let page) = try decode(frame) else {
                throw Failure.invalidFrame
            }
            switch page {
            case .version:
                state.firmware = String(
                    format: "%02X.%02X.%02X", frame[4], frame[5], frame[6])
            case .audio:
                guard Command.volume.accepts(frame[4]),
                      Command.gain.accepts(frame[5]),
                      Command.filter.accepts(frame[6]),
                      Command.balance.accepts(frame[7]) else {
                    throw Failure.invalidFrame
                }
                state.volume = Int(frame[4])
                state.gain = Int(frame[5])
                state.filter = Int(frame[6])
                state.balance = Int(Int8(bitPattern: frame[7]))
            case .display:
                guard Command.brightness.accepts(frame[4]),
                      Command.screenTimeout.accepts(frame[5]),
                      Command.orientation.accepts(frame[6]) else {
                    throw Failure.invalidFrame
                }
                state.brightness = Int(frame[4])
                state.screenTimeout = Int(frame[5])
                state.orientation = Int(frame[6])
            case .offset:
                guard Command.screenOffset.accepts(frame[4]) else {
                    throw Failure.invalidFrame
                }
                state.screenOffset = Int(frame[4]) - screenOffsetBias
            case .acknowledgement:
                throw Failure.invalidFrame
            }
        }

        static func isTerminator(_ frame: [UInt8]) -> Bool {
            frame.count == inputReportLength
                && frame[0] == 0x01
                && frame.dropFirst().allSatisfy { $0 == 0 }
        }

        static func isValidDataFrame(_ frame: [UInt8]) -> Bool {
            guard frame.count == inputReportLength,
                  frame[0] == 0x01,
                  frame[1] == 0x55,
                  frame[2] == 0xAA else { return false }
            return frame[inputReportLength - 1]
                == checksum(frame[1..<(inputReportLength - 1)])
        }

        private static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
            let sum = bytes.reduce(0) { $0 + Int($1) }
            return UInt8(~sum & 0xFF)
        }
    }
}
