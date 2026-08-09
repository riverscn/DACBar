import SwiftUI

@main
@MainActor
struct DACBarApp: App {
    @State private var model = DeviceModel()
    @State private var updates = UpdateController()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model, updates: updates)
        } label: {
            // Dimmed when the dongle is unplugged, so the menu bar says whether
            // there is anything to control without the panel being opened.
            Image(nsImage: DeviceGlyph.menuBar(present: model.devicePresent))
                .accessibilityLabel(AppL10n.text(
                    "app.accessibility.controls",
                    defaultValue: "DAC device controls"))
                .accessibilityValue(model.devicePresent
                    ? AppL10n.text("app.accessibility.device-present", defaultValue: "Device detected")
                    : AppL10n.text("app.accessibility.device-absent", defaultValue: "No device detected"))
        }
        .menuBarExtraStyle(.window)
    }
}
