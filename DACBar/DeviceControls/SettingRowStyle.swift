import DACDeviceKit
import SwiftUI

/// The one definition of a control row's chrome.
///
/// Every model's settings reach the panel through `DeviceControlsView`, so a
/// plug-in decides only *what* a row says — its title, glyph, options and
/// value. Geometry lives here, which is what keeps a second vendor from
/// drifting into a layout of its own.
enum SettingRowMetrics {
    static let titleFont: Font = .callout
    static let verticalPadding: CGFloat = 4
    /// Minimum gutter between a row's label and its control.
    static let labelGutter: CGFloat = 8
    /// Reserved for the glyph. SF Symbols differ in width — `speaker.wave.2`
    /// is far wider than `cable.connector` — and a plain `Label` starts its
    /// title right after whatever it drew, so the column of titles wanders
    /// down the panel. A fixed box makes every title start at the same x.
    static let iconWidth: CGFloat = 17
    static let iconGutter: CGFloat = 6
}

private struct SettingRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SettingRowMetrics.iconGutter) {
            configuration.icon
                .frame(width: SettingRowMetrics.iconWidth)
            configuration.title
                // A segmented picker's minimum width is large enough to fold a
                // four-character title onto two lines. The title is the thing
                // being read, so it keeps its width and the control gives way.
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Leading glyph and title, identical for every presentation.
struct SettingRowLabel: View {
    let setting: DACDeviceKit.SettingDescriptor

    var body: some View {
        Label(setting.title, systemImage: setting.systemImage)
            .font(SettingRowMetrics.titleFont)
            .labelStyle(SettingRowLabelStyle())
    }
}

/// Title hard against the left, control hard against the right: the one row
/// shape every single-line presentation uses.
///
/// Controls that size to their content — a switch, a read-out, a colour well —
/// do not reach the trailing edge on their own, so they are laid out here
/// rather than left to place themselves.
struct SettingRow<Control: View>: View {
    let setting: DACDeviceKit.SettingDescriptor
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: SettingRowMetrics.labelGutter) {
            SettingRowLabel(setting: setting)
                .layoutPriority(1)
            Spacer(minLength: SettingRowMetrics.labelGutter)
            control
        }
        .settingRow()
    }
}

private struct SettingRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, SettingRowMetrics.verticalPadding)
    }
}

extension View {
    /// Applies the shared row chrome. Rows use this instead of their own
    /// padding or alignment.
    func settingRow() -> some View {
        modifier(SettingRowChrome())
    }
}
