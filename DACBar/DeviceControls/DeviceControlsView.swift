import AppKit
import DACDeviceKit
import SwiftUI

/// Capability-driven control surface. The root view no longer knows which
/// settings a model exposes; it only composes the groups supplied by its
/// driver.
struct DeviceControlsView: View {
    let settings: [DACDeviceKit.SettingDescriptor]
    let value: (DACDeviceKit.SettingID) -> Int?
    let textValue: (DACDeviceKit.SettingID) -> String?
    let onChange: (DACDeviceKit.SettingID, Int) -> Void

    private var groups: [DACDeviceKit.SettingGroup] {
        settings.reduce(into: []) { result, setting in
            if !result.contains(setting.group) { result.append(setting.group) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(groups) { group in
                groupView(group)
            }
        }
        .padding(.horizontal, PanelMetrics.contentInset)
        .padding(.bottom, PanelMetrics.contentInset)
    }

    @ViewBuilder
    private func groupView(_ group: DACDeviceKit.SettingGroup) -> some View {
        if group.isCollapsible {
            CollapsibleSettingGroup(group: group) {
                rows(in: group)
                    .padding(.top, 4)
            }
        } else {
            rows(in: group)
        }
    }

    private func rows(in group: DACDeviceKit.SettingGroup) -> some View {
        VStack(spacing: 2) {
            ForEach(settings.filter { $0.group == group }) { setting in
                let current = value(setting.id)
                let text = textValue(setting.id)
                if current != nil || text != nil {
                    DeviceSettingRow(
                        setting: setting,
                        value: current,
                        textValue: text,
                        onChange: { onChange(setting.id, $0) })
                }
            }
        }
    }

}

struct SettingGroupExpansionPreference: Equatable {
    let key: String
    let defaultValue: Bool

    init(group: DACDeviceKit.SettingGroup) {
        if group.id == DACDeviceKit.SettingGroup.display.id {
            key = "showDisplaySection"
            defaultValue = false
        } else {
            key = "settingGroup.\(group.id).isExpanded"
            defaultValue = true
        }
    }

    func storage(store: UserDefaults? = nil) -> AppStorage<Bool> {
        AppStorage(wrappedValue: defaultValue, key, store: store)
    }
}

private struct CollapsibleSettingGroup<Content: View>: View {
    let group: DACDeviceKit.SettingGroup
    let content: Content

    @AppStorage private var isExpanded: Bool

    init(
        group: DACDeviceKit.SettingGroup,
        @ViewBuilder content: () -> Content
    ) {
        self.group = group
        self.content = content()
        _isExpanded = SettingGroupExpansionPreference(group: group).storage()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            Text(group.title).font(.callout)
        }
        .padding(.top, 10)
    }
}

private struct DeviceSettingRow: View {
    let setting: DACDeviceKit.SettingDescriptor
    let value: Int?
    let textValue: String?
    let onChange: (Int) -> Void

    @ViewBuilder
    var body: some View {
        switch setting.presentation {
        case .range(let minimum, let maximum, let step, let format):
            if let value {
                SettingSliderRow(
                    setting: setting,
                    value: value,
                    range: minimum...maximum,
                    step: step,
                    formattedValue: format.string(for: value),
                    onChange: onChange)
            }
        case .options(let options):
            if let value {
                SettingOptionsRow(
                    setting: setting,
                    value: value,
                    options: options,
                    onChange: onChange)
            }
        case .toggle:
            if let value {
                SettingToggleRow(setting: setting, value: value != 0) {
                    onChange($0 ? 1 : 0)
                }
            }
        case .color:
            if let value {
                SettingColorRow(setting: setting, value: value, onChange: onChange)
            }
        case .readOnly:
            if let displayed = textValue ?? value.map(String.init) {
                SettingReadOnlyRow(setting: setting, value: displayed)
            }
        }
    }
}

private struct SettingSliderRow: View {
    let setting: DACDeviceKit.SettingDescriptor
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let formattedValue: String
    let onChange: (Int) -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                SettingRowLabel(setting: setting)
                Spacer()
                Text(formattedValue)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Int($0.rounded())) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step),
                label: { Text(setting.title) })
            .controlSize(.small)
            .labelsHidden()
            .accessibilityValue(formattedValue)
        }
        .settingRow()
    }
}

private struct SettingOptionsRow: View {
    let setting: DACDeviceKit.SettingDescriptor
    let value: Int
    let options: [DACDeviceKit.SettingOption]
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: SettingRowMetrics.labelGutter) {
            HStack(spacing: 4) {
                SettingRowLabel(setting: setting)
                if let explainer {
                    explainer
                }
            }
            .layoutPriority(1)

            Spacer(minLength: SettingRowMetrics.labelGutter)

            picker
        }
        .settingRow()
    }

    /// A segmented control shows every option at once, which is worth the
    /// width when the options are few and short. Once they are not, the same
    /// choice has to become a pop-up button or it squeezes the title and its
    /// own labels. Asking the layout whether the segments fit decides that per
    /// row and per panel width, instead of each driver guessing.
    private var picker: some View {
        ViewThatFits(in: .horizontal) {
            basePicker
                .pickerStyle(.segmented)
                .labelsHidden()
            basePicker
                .pickerStyle(.menu)
                .labelsHidden()
                .buttonStyle(.borderless)
                .fixedSize()
        }
    }

    private var basePicker: some View {
        Picker(
            setting.title,
            selection: Binding(get: { value }, set: { onChange($0) })
        ) {
            ForEach(options) { option in
                Text(option.label).tag(option.value)
            }
        }
    }

    private var explainer: SettingExplainer? {
        guard let summary = setting.explanation else { return nil }
        let notes = options.compactMap { option -> (name: String, note: String)? in
            guard let note = option.note else { return nil }
            return (option.label, note)
        }
        return SettingExplainer(
            summary: summary,
            options: notes,
            accessibilityName: AppL10n.format(
                "settings.explanation.accessibility",
                defaultValue: "About %@",
                setting.title))
    }
}

private struct SettingToggleRow: View {
    let setting: DACDeviceKit.SettingDescriptor
    let value: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        SettingRow(setting: setting) {
            Toggle(
                isOn: Binding(get: { value }, set: { onChange($0) }),
                label: { EmptyView() })
                .toggleStyle(.switch)
                // Apple's guidance for a switch that controls a single row in
                // a grouped form: the mini size is close to the height of the
                // pickers and read-outs beside it, so rows stay even.
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(setting.title)
        }
    }
}

private struct SettingReadOnlyRow: View {
    let setting: DACDeviceKit.SettingDescriptor
    let value: String

    var body: some View {
        SettingRow(setting: setting) {
            Text(value)
                .font(SettingRowMetrics.titleFont)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingColorRow: View {
    let setting: DACDeviceKit.SettingDescriptor
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        SettingRow(setting: setting) {
            ColorPicker(
                selection: Binding(
                    get: { value.color },
                    set: { onChange($0.packedRGB) }),
                supportsOpacity: false,
                label: { EmptyView() })
                .labelsHidden()
                .accessibilityLabel(setting.title)
        }
    }
}

private extension DACDeviceKit.ValueFormat {
    func string(for value: Int) -> String {
        switch self {
        case .number:
            return String(value)
        case .balance:
            if value == 0 {
                return AppL10n.text("balance.center", defaultValue: "Center")
            }
            return value < 0
                ? AppL10n.format("balance.left", defaultValue: "Left %lld", Int64(-value))
                : AppL10n.format("balance.right", defaultValue: "Right %lld", Int64(value))
        }
    }
}

private extension Int {
    var color: Color {
        Color(
            red: Double((self >> 16) & 0xFF) / 255,
            green: Double((self >> 8) & 0xFF) / 255,
            blue: Double(self & 0xFF) / 255)
    }
}

private extension Color {
    var packedRGB: Int {
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return 0 }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }
}

// MARK: - Previews

/// Drives `DeviceControlsView` from a local snapshot, so the controls respond
/// without a driver at all.
private struct PreviewControls: View {
    let fixture: PreviewDevices.Fixture
    @State private var snapshot: DACDeviceKit.Snapshot

    init(fixture: PreviewDevices.Fixture) {
        self.fixture = fixture
        _snapshot = State(initialValue: fixture.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(fixture.profile.displayName)
                .font(.title3)
                .padding(.horizontal, PanelMetrics.contentInset)
                .padding(.top, 12)
            DeviceControlsView(
                settings: fixture.settings,
                value: { snapshot[$0] },
                textValue: { snapshot.textValues[$0] },
                onChange: { snapshot[$0] = $1 })
        }
        .frame(width: PanelMetrics.panelWidth, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Controls · side by side") {
    HStack(alignment: .top, spacing: 0) {
        PreviewControls(fixture: PreviewDevices.shanlingUA1II)
        Divider()
        PreviewControls(fixture: PreviewDevices.secondModel)
    }
    .fixedSize()
}
