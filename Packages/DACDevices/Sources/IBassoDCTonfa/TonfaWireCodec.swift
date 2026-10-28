import Foundation

extension IBassoDCTonfa {
    enum Section: CaseIterable, Equatable, Sendable {
        case firmware
        case filter
        case volume
        case audio
        case screen
    }

    enum Setting: Equatable, Sendable {
        case volume(Int)
        case filter(Int)
        case gain(Int)
        case balance(Int)
        case coaxialOutput(Int)
        case keyControl(Int)
        case screenTimeout(Int)
        case orientation(Int)

        var value: Int {
            switch self {
            case .volume(let value), .filter(let value), .gain(let value),
                 .balance(let value), .coaxialOutput(let value),
                 .keyControl(let value), .screenTimeout(let value),
                 .orientation(let value):
                return value
            }
        }
    }

    struct State: Equatable, Sendable {
        var valid = false
        var volume = 0
        var filter = 0
        /// Tonfa wire enum: 0 = low, 1 = medium, 2 = high.
        var gain = 0
        /// Logical units: -10 is full left, 0 is centered, 10 is full right.
        var balance = 0
        var coaxialOutput = 0
        var keyControl = 0
        /// Tonfa wire enum: 0 = 10s, 1 = 20s, 2 = 30s, 3 = always on.
        var screenTimeout = 0
        var orientation = 0
        var firmware = ""

        mutating func apply(_ setting: Setting) {
            switch setting {
            case .volume(let value): volume = value
            case .filter(let value): filter = value
            case .gain(let value): gain = value
            case .balance(let value): balance = value
            case .coaxialOutput(let value): coaxialOutput = value
            case .keyControl(let value): keyControl = value
            case .screenTimeout(let value): screenTimeout = value
            case .orientation(let value): orientation = value
            }
        }

        func changes(to other: State) -> [Setting] {
            var result: [Setting] = []
            if volume != other.volume { result.append(.volume(other.volume)) }
            if filter != other.filter { result.append(.filter(other.filter)) }
            if gain != other.gain { result.append(.gain(other.gain)) }
            if balance != other.balance { result.append(.balance(other.balance)) }
            if coaxialOutput != other.coaxialOutput {
                result.append(.coaxialOutput(other.coaxialOutput))
            }
            if keyControl != other.keyControl {
                result.append(.keyControl(other.keyControl))
            }
            if screenTimeout != other.screenTimeout {
                result.append(.screenTimeout(other.screenTimeout))
            }
            if orientation != other.orientation {
                result.append(.orientation(other.orientation))
            }
            return result
        }
    }

    enum TonfaWireCodec {
        static let reportLength = 8

        static func query(_ section: Section) -> [UInt8] {
            switch section {
            case .firmware: return [0x58, 0xF1, 0x0E, 0, 0, 0, 0, 0]
            case .filter:   return [0x59, 0x21, 0xDE, 0, 0, 0, 0, 0]
            case .volume:   return [0x42, 0x11, 0xEE, 0, 0, 0, 0, 0]
            case .audio:    return [0x60, 0x31, 0xCE, 0, 0, 0, 0, 0]
            case .screen:   return [0x61, 0x41, 0xBE, 0, 0, 0, 0, 0]
            }
        }

        static func encode(_ setting: Setting, state: State) throws -> [UInt8] {
            var target = state
            target.apply(setting)
            try validate(setting)

            switch setting {
            case .volume(let value):
                return [0x01, 0x10, 0xEF, UInt8(value), UInt8(value), 0, 0, 0]
            case .filter(let value):
                return [0x11, 0x20, 0xDF, 0, UInt8(value), 0, 0, 0]
            case .gain, .balance, .coaxialOutput:
                return [
                    0x19, 0x30, 0xCF, 0,
                    UInt8(target.coaxialOutput), UInt8(target.balance + 10),
                    UInt8(target.gain), 0,
                ]
            case .keyControl, .screenTimeout, .orientation:
                return [
                    0x19, 0x40, 0xBF, 0,
                    UInt8(target.orientation), UInt8(target.keyControl),
                    UInt8(target.screenTimeout), 0,
                ]
            }
        }

        static func section(of frame: [UInt8]) -> Section? {
            guard frame.count == reportLength else { return nil }
            switch (frame[0], frame[1]) {
            case (0x58, _), (0, 0xF1): return .firmware
            case (0x59, _), (0, 0x22), (0x11, 0x20): return .filter
            case (0x42, _), (0, 0x12), (0x01, 0x10): return .volume
            case (0x60, _), (0, 0x32), (0x19, 0x30): return .audio
            case (0x61, _), (0, 0x42), (0x19, 0x40): return .screen
            default: return nil
            }
        }

        static func apply(_ frame: [UInt8], to state: inout State) throws {
            guard let section = section(of: frame) else { throw Failure.invalidFrame }
            switch section {
            case .firmware:
                state.firmware = "\(frame[4]).\(frame[5]).\(String(format: "%02X", frame[6]))"
            case .filter:
                guard (0...4).contains(frame[4]) else { throw Failure.invalidFrame }
                state.filter = Int(frame[4])
            case .volume:
                guard frame[4] <= 100 else { throw Failure.invalidFrame }
                state.volume = Int(frame[4])
            case .audio:
                guard frame[4] <= 1, frame[5] <= 20, frame[6] <= 2 else {
                    throw Failure.invalidFrame
                }
                state.coaxialOutput = Int(frame[4])
                state.balance = Int(frame[5]) - 10
                state.gain = Int(frame[6])
            case .screen:
                guard frame[4] <= 1, frame[5] <= 1, frame[6] <= 3 else {
                    throw Failure.invalidFrame
                }
                state.orientation = Int(frame[4])
                state.keyControl = Int(frame[5])
                state.screenTimeout = Int(frame[6])
            }
        }

        static func validate(_ setting: Setting) throws {
            let valid: Bool
            switch setting {
            case .volume(let value): valid = (0...100).contains(value)
            case .filter(let value): valid = (0...4).contains(value)
            case .gain(let value): valid = (0...2).contains(value)
            case .coaxialOutput(let value), .keyControl(let value),
                 .orientation(let value):
                valid = (0...1).contains(value)
            case .balance(let value): valid = (-10...10).contains(value)
            case .screenTimeout(let value): valid = (0...3).contains(value)
            }
            guard valid else { throw Failure.invalidValue(setting) }
        }
    }
}
