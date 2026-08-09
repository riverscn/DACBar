import SwiftUI

/// An info button that explains a setting, and what choosing each of its
/// options does.
///
/// A button rather than a tooltip: `.help()` is ignored on menu entries, so the
/// per-option notes could not live there, and hovering is not a thing people do
/// to look for an explanation. Clicking shows everything at once, which also
/// lets the options be compared — the reason to open this at all.
struct SettingExplainer: View {

    /// What the setting is for.
    let summary: String
    /// Each option, paired with what it does.
    let options: [(name: String, note: String)]
    let accessibilityName: String

    init(summary: String, options: [(name: String, note: String)],
         accessibilityName: String = AppL10n.text(
            "settings.explanation", defaultValue: "Explanation")) {
        self.summary = summary
        self.options = options
        self.accessibilityName = accessibilityName
    }

    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(showing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentShape(.rect)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(options, id: \.name) { option in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.name)
                            .font(.callout.weight(.medium))
                        Text(option.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        // Wide enough that the option notes stay two lines at most; the popover
        // has no other reason to pick a width.
        .frame(width: 300)
    }
}
