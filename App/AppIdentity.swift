import Foundation

enum AppIdentity {
    /// Uses the processed bundle identifier so logs follow deliberate build-
    /// setting overrides without introducing another compile-time default.
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "DACBar"
}
