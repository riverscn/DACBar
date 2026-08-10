import DACDeviceKit

/// Convenience accessors for settings exposed by the current control surface.
/// The capability-driven dictionary remains authoritative, so adding a model
/// does not expand the observable model or the SwiftUI control surface.
extension DACDeviceKit.Snapshot {
    var volume: Int {
        get { self[.volume] ?? 0 }
        set { self[.volume] = newValue }
    }
    var gain: Int {
        get { self[.gain] ?? 0 }
        set { self[.gain] = newValue }
    }
    var filter: Int {
        get { self[.filter] ?? 0 }
        set { self[.filter] = newValue }
    }
    var balance: Int {
        get { self[.balance] ?? 0 }
        set { self[.balance] = newValue }
    }
    var brightness: Int {
        get { self[.brightness] ?? 0 }
        set { self[.brightness] = newValue }
    }
    var screenTimeout: Int {
        get { self[.screenTimeout] ?? 0 }
        set { self[.screenTimeout] = newValue }
    }
    var orientation: Int {
        get { self[.orientation] ?? 0 }
        set { self[.orientation] = newValue }
    }
    var screenOffset: Int {
        get { self[.screenOffset] ?? 0 }
        set { self[.screenOffset] = newValue }
    }
}
