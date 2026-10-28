import DACDeviceKit
import SwiftUI

/// The one definition of a control row's chrome.
///
/// Every model's settings reach the panel through `DeviceControlsView`, so a
/// plug-in decides only *what* a row says — its title, glyph, options and
/// value. Font, spacing and the leading-label/trailing-control alignment live
/// here, which is what keeps a second vendor from drifting into a layout of
/// its own.
enum SettingRowMetrics {
    static let titleFont: Font = .callout
    static let verticalPadding: CGFloat = 4
    /// Minimum gutter between a row's label and its control.
    static let labelGutter: CGFloat = 8
}

/// Leading title and glyph, identical for every presentation.
struct SettingRowLabel: View {
    let setting: DACDeviceKit.SettingDescriptor

    var body: some View {
        Label(setting.title, systemImage: setting.systemImage)
            .font(SettingRowMetrics.titleFont)
            .labelStyle(.titleAndIcon)
    }
}

private struct SettingRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Explicitly full width and leading-aligned: a row whose content
            // happens not to be greedy (a lone picker, a short read-out) would
            // otherwise centre itself in the panel and read as a different
            // design from the rows around it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, SettingRowMetrics.verticalPadding)
    }
}

extension View {
    /// Applies the shared row chrome. Control rows use this instead of their
    /// own padding or alignment.
    func settingRow() -> some View {
        modifier(SettingRowChrome())
    }
}
