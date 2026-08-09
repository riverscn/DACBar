import Foundation

extension DACDeviceKit {

    /// Stable model identity used by discovery, selection persistence and the
    /// driver factory. It deliberately does not use the USB product string,
    /// which firmware revisions are free to change.
    public struct ModelID: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

    }

    /// Stable identifier selected by the App's composition root. Concrete
    /// device modules own their values; the core never enumerates vendors.
    public struct DriverID: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public enum DiscoveryKind: String, Hashable, Sendable, Codable {
        /// Implemented by the current IOHIDManager watcher.
        case hidService
        /// Reserved vocabulary for a future model that cannot be discovered as
        /// an HID service. No USB-registry backend is implemented yet.
        case usbRegistry
    }

    public enum TransportKind: String, Hashable, Sendable, Codable {
        /// Implemented by device modules that communicate with HID reports.
        case hidReports
        /// Reserved until a matching model is verified on macOS.
        case vendorControl
        /// Reserved until a matching model is verified on macOS.
        case interruptEndpoints
        /// Reserved until a matching model is verified on macOS.
        case hidFeatureInterrupt
    }

    public enum VerificationStatus: Hashable, Sendable {
        case verified(hardware: String, firmware: String?)
        case experimental
    }

    /// One HID service signature accepted for a model. A profile may expose
    /// several signatures when firmware revisions use different PIDs or HID
    /// collections.
    public struct HIDMatch: Hashable, Sendable {
        public let vendorID: Int
        public let productID: Int
        public let usagePage: Int
        public let usage: Int
        public let inputReportSize: Int
        public let outputReportSize: Int

        public init(
            vendorID: Int,
            productID: Int,
            usagePage: Int,
            usage: Int,
            inputReportSize: Int,
            outputReportSize: Int
        ) {
            self.vendorID = vendorID
            self.productID = productID
            self.usagePage = usagePage
            self.usage = usage
            self.inputReportSize = inputReportSize
            self.outputReportSize = outputReportSize
        }
    }

    public struct DeviceProfile: Identifiable, Hashable, Sendable {
        public let id: ModelID
        public let displayName: String
        public let productNames: [String]
        public let hidMatches: [HIDMatch]
        public let discoveryKind: DiscoveryKind
        public let transportKind: TransportKind
        public let driverID: DriverID
        public let verification: VerificationStatus

        public init(
            id: ModelID,
            displayName: String,
            productNames: [String],
            hidMatches: [HIDMatch],
            discoveryKind: DiscoveryKind,
            transportKind: TransportKind,
            driverID: DriverID,
            verification: VerificationStatus
        ) {
            self.id = id
            self.displayName = displayName
            self.productNames = productNames
            self.hidMatches = hidMatches
            self.discoveryKind = discoveryKind
            self.transportKind = transportKind
            self.driverID = driverID
            self.verification = verification
        }
    }

    /// Runtime-supported devices. A profile belongs here only after its
    /// discovery backend, transport and driver all exist; enum cases above are
    /// vocabulary for future work, not a promise that their backend exists.
    public struct DeviceRegistry: Sendable {
        public let profiles: [DeviceProfile]

        public init(profiles: [DeviceProfile]) {
            self.profiles = profiles
        }

        public var hidMatches: [HIDMatch] {
            profiles.filter { $0.discoveryKind == .hidService }
                .flatMap(\.hidMatches)
        }

        public func profile(
            vendorID: Int,
            productID: Int,
            productName: String,
            usagePage: Int,
            usage: Int,
            inputReportSize: Int,
            outputReportSize: Int
        ) -> DeviceProfile? {
            let candidates = profiles.filter { profile in
                guard profile.discoveryKind == .hidService else { return false }
                return profile.hidMatches.contains { match in
                    match.vendorID == vendorID
                        && match.productID == productID
                        && match.usagePage == usagePage
                        && match.usage == usage
                        && match.inputReportSize == inputReportSize
                        && match.outputReportSize == outputReportSize
                }
            }
            guard !candidates.isEmpty else { return nil }

            // A unique USB/HID signature is authoritative even if a firmware
            // revision changes or localizes its product string. Shared IDs must
            // be disambiguated by an exact normalized model name.
            if candidates.count == 1 { return candidates[0] }
            let normalized = Self.normalize(productName)
            return candidates.first { profile in
                profile.productNames.contains {
                    Self.normalize($0) == normalized
                        || normalized.hasSuffix(" " + Self.normalize($0))
                }
            }
        }

        public func profile(id: ModelID) -> DeviceProfile? {
            profiles.first { $0.id == id }
        }

        private static func normalize(_ value: String) -> String {
            value.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .lowercased()
        }
    }

    /// A discovered device expressed without any vendor-specific protocol
    /// types. Physical location remains part of identity because some USB DACs
    /// expose no unique serial number.
    public struct Device: Sendable, Equatable, Identifiable {
        public struct ID: Hashable, Sendable {
            public let model: ModelID
            public let locationID: UInt32

            public init(model: ModelID, locationID: UInt32) {
                self.model = model
                self.locationID = locationID
            }
        }

        public let profile: DeviceProfile
        public let productID: Int
        public let locationID: UInt32
        public let registryEntryID: UInt64
        public let name: String

        public init(
            profile: DeviceProfile,
            productID: Int,
            locationID: UInt32,
            registryEntryID: UInt64,
            name: String
        ) {
            self.profile = profile
            self.productID = productID
            self.locationID = locationID
            self.registryEntryID = registryEntryID
            self.name = name
        }

        public var id: ID { ID(model: profile.id, locationID: locationID) }

        public var portPath: String {
            let bus = (locationID >> 24) & 0xFF
            var ports: [String] = []
            let remaining = locationID & 0x00FF_FFFF
            for shift in stride(from: 20, through: 0, by: -4) {
                let nibble = (remaining >> UInt32(shift)) & 0xF
                if nibble != 0 { ports.append(String(nibble)) }
            }
            return ([String(bus)] + ports).joined(separator: "-")
        }
    }
}
