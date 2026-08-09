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

    @AppStorage("showDisplaySection") private var showDisplaySection = false

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
            DisclosureGroup(isExpanded: expansionBinding(for: group)) {
                rows(in: group)
                    .padding(.top, 4)
            } label: {
                Text(group.title).font(.callout)
            }
            .padding(.top, 10)
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

    private func expansionBinding(for group: DACDeviceKit.SettingGroup) -> Binding<Bool> {
        // Preserve the existing display preference. Future collapsible groups
        // can introduce their own stable AppStorage keys without affecting the
        // driver/capability model.
        if group.id == DACDeviceKit.SettingGroup.display.id {
            return $showDisplaySection
        }
        return .constant(true)
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
        case .segmented(let options):
            if let value {
                SettingOptionsRow(
                    setting: setting,
                    value: value,
                    options: options,
                    style: .segmented,
                    onChange: onChange)
            }
        case .menu(let options):
            if let value {
                SettingOptionsRow(
                    setting: setting,
                    value: value,
                    options: options,
                    style: .menu,
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
                Label(setting.title, systemImage: setting.systemImage)
                    .font(.callout)
                    .labelStyle(.titleAndIcon)
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
        .padding(.vertical, 4)
    }
}

private struct SettingOptionsRow: View {
    enum Style { case segmented, menu }

    let setting: DACDeviceKit.SettingDescriptor
    let value: Int
    let options: [DACDeviceKit.SettingOption]
    let style: Style
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Label(setting.title, systemImage: setting.systemImage)
                    .font(.callout)
                    .labelStyle(.titleAndIcon)
                if let explainer {
                    explainer
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            picker
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var picker: some View {
        switch style {
        case .segmented:
            basePicker
                .pickerStyle(.segmented)
                .labelsHidden()
        case .menu:
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
        Toggle(
            isOn: Binding(get: { value }, set: { onChange($0) }),
            label: {
                Label(setting.title, systemImage: setting.systemImage)
                    .font(.callout)
                    .labelStyle(.titleAndIcon)
            })
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.vertical, 4)
    }
}

private struct SettingReadOnlyRow: View {
    let setting: DACDeviceKit.SettingDescriptor
    let value: String

    var body: some View {
        LabeledContent {
            Text(value).foregroundStyle(.secondary)
        } label: {
            Label(setting.title, systemImage: setting.systemImage)
                .font(.callout)
                .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
    }
}

private struct SettingColorRow: View {
    let setting: DACDeviceKit.SettingDescriptor
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        ColorPicker(
            selection: Binding(
                get: { value.color },
                set: { onChange($0.packedRGB) }),
            supportsOpacity: false,
            label: {
                Label(setting.title, systemImage: setting.systemImage)
                    .font(.callout)
                    .labelStyle(.titleAndIcon)
            })
        .padding(.vertical, 4)
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
